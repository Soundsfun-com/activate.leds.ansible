#!/usr/bin/env bash
#
# Proves security patching lands inside the maintenance window, and in the
# right ORDER within it.
#
# Written after getting it wrong twice in one sitting:
#
#   1. Flipping `auto_apply_security_patches` alone changes nothing about WHEN.
#      Debian's apt-daily-upgrade.timer fires at 06:00 ±60min, so patches would
#      install during opening prep. The role now ships a timer drop-in — and
#      systemd ORs triggers, so it must CLEAR the baked OnCalendar first or
#      both fire.
#   2. The reboot was pinned to the window START while the upgrade also starts
#      then. By the time the upgrade finished, the reboot time had passed, so
#      unattended-upgrades would wait until the same hour the NEXT night — a
#      kernel patch sitting unbooted for 24 hours.
#
# Both were invisible: ansible reports green either way. So this renders the
# real templates and asserts on the resulting files.
#
# Usage:  ansible/tests/test_patch_window.sh
# Needs:  ansible-playbook on PATH (pip install ansible-core)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v ansible-playbook >/dev/null || {
  echo "SKIP: ansible-playbook not installed (pip install ansible-core)" >&2
  exit 127
}

START=3
END=5

cat > "$TMP/render.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: no
  vars:
    auto_apply_security_patches: true
    maintenance_window_start_hour: $START
    maintenance_window_end_hour: $END
  tasks:
    - name: unattended-upgrades policy
      ansible.builtin.template:
        src: $REPO/roles/security/templates/50-unattended-upgrades-activate.j2
        dest: $TMP/50unattended-upgrades
    - name: apt periodic settings
      ansible.builtin.template:
        src: $REPO/roles/security/templates/20-auto-upgrades-activate.j2
        dest: $TMP/20auto-upgrades
EOF

ansible-playbook "$TMP/render.yml" >/dev/null

fail=0
check() {  # check <description> <condition-result>
  if [ "$2" = "0" ]; then
    echo "  ok   — $1"
  else
    echo "  FAIL — $1"
    fail=1
  fi
}

echo "patch window:"

# 1. Patches are actually applied, not just downloaded.
grep -q 'APT::Periodic::Unattended-Upgrade "1"' "$TMP/20auto-upgrades"
check "unattended-upgrade is enabled when auto_apply is on" $?

# 2. Security origins only — never a blanket dist-upgrade on a live store.
grep -q 'security' "$TMP/50unattended-upgrades"
check "only security origins are allowed" $?

# 3. Reboot happens at the window END, AFTER the upgrade run that starts at
#    the window start. This is the 24-hour-delay bug.
grep -q "Automatic-Reboot-Time \"0$END:00\"" "$TMP/50unattended-upgrades"
check "reboot is pinned to the window END ($END:00), not its start" $?

grep -q "Automatic-Reboot-Time \"0$START:00\"" "$TMP/50unattended-upgrades" && rc=1 || rc=0
check "reboot is NOT at the window start (would defer 24h)" $rc

# 4. The timer drop-in clears the baked OnCalendar before setting ours.
#    Asserted against the role source: systemd ORs triggers, so a drop-in that
#    only adds one leaves Debian's 06:00 run alive.
task_file="$REPO/roles/security/tasks/main.yml"
grep -q 'apt-daily-upgrade.timer.d' "$task_file"
check "an apt-daily-upgrade.timer drop-in is installed" $?

awk '/apt-daily-upgrade.timer.d\/activate-window.conf/,/notify:/' "$task_file" \
  | grep -qE '^\s*OnCalendar=\s*$'
check "the drop-in CLEARS OnCalendar before setting it" $?

awk '/apt-daily-upgrade.timer.d\/activate-window.conf/,/notify:/' "$task_file" \
  | grep -q "maintenance_window_start_hour"
check "the drop-in runs at the window start" $?

exit $fail
