#!/usr/bin/env bash
#
# Proves an UNCLAIMED Pi converges within minutes while a CLAIMED store keeps
# the quiet 2am schedule.
#
# Why this test exists:
#
#   The pi-gen image doesn't bake the agent code — only its venv. The agent
#   arrives with the first ansible-pull, and nothing announces the Pi to the
#   dashboard's Assign tab until that agent runs. So for an unclaimed Pi the
#   convergence cadence IS the time-to-appear. When 079a900 moved the fleet to
#   once-daily, it silently moved fresh Pis onto that schedule too: flash a box,
#   wait until 2am to be able to assign it.
#
#   Worse, `base` runs BEFORE `activate-agent` in site.yml, so the drop-in lands
#   before the agent exists. With the daily cadence written unconditionally, any
#   later failure in the play retired the image's hourly retry and left a Pi with
#   no agent and no retry until 2am — and a Pi with no agent can't report that.
#
# Both were invisible: ansible reports green either way, and the affected Pi is
# by definition the one that can't tell anyone. So render the real template for
# both branches and assert.
#
# Usage:  ansible/tests/test_pull_cadence.sh
# Needs:  ansible-playbook on PATH (pip install ansible-core)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v ansible-playbook >/dev/null || {
  echo "SKIP: ansible-playbook not installed (pip install ansible-core)" >&2
  exit 127
}

# Render the real template twice, driving it exactly the way roles/base does:
# the set_fact in tasks/main.yml picks the effective values off `site_slug`.
# Defaults come from the role's own defaults/main.yml so a changed default is
# covered rather than restated here.
cat > "$TMP/render.yml" <<EOF
- hosts: localhost
  connection: local
  gather_facts: no
  vars_files:
    - $REPO/roles/base/defaults/main.yml
  tasks:
    - name: claimed store (site-identity found a slug in agent.toml)
      ansible.builtin.set_fact:
        site_slug: plano
        activate_pi_claimed: true
        ansible_pull_effective_oncalendar: "{{ ansible_pull_oncalendar }}"
        ansible_pull_effective_delay: "{{ ansible_pull_randomized_delay }}"
    - ansible.builtin.template:
        src: $REPO/roles/base/templates/ansible-pull-cadence.conf.j2
        dest: $TMP/cadence-claimed.conf

    - name: unclaimed Pi (no agent.toml, so no slug)
      ansible.builtin.set_fact:
        site_slug: ""
        activate_pi_claimed: false
        ansible_pull_effective_oncalendar: "{{ ansible_pull_unassigned_oncalendar }}"
        ansible_pull_effective_delay: "{{ ansible_pull_unassigned_randomized_delay }}"
    - ansible.builtin.template:
        src: $REPO/roles/base/templates/ansible-pull-cadence.conf.j2
        dest: $TMP/cadence-unclaimed.conf
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
# Every assertion below runs its grep through `&& rc=0 || rc=1` rather than
# `grep; check $?`. Under `set -e` the bare form aborts the script on the FIRST
# failing grep, so a broken cadence would print one FAIL and hide the rest.
has()   { grep -qE "$1" "$2" && rc=0 || rc=1; }
lacks() { grep -qE "$1" "$2" && rc=1 || rc=0; }
hasF()  { grep -qF "$1" "$2" && rc=0 || rc=1; }   # fixed string: no regex escaping

echo "ansible-pull cadence:"

# 1. A claimed store still converges overnight, not during trading hours.
has '^OnCalendar=\*-\*-\* 02:00:00$' "$TMP/cadence-claimed.conf"
check "a claimed store converges at 02:00 local" $rc

# 2. An unclaimed Pi does NOT inherit the daily schedule. This is the bug:
#    time-to-appear on the Assign tab equals time-to-first-pull.
lacks '^OnCalendar=\*-\*-\* 02:00:00$' "$TMP/cadence-unclaimed.conf"
check "an unclaimed Pi is NOT left on the 02:00 daily schedule" $rc

# 3. …and converges on a sub-hour repeat instead. Accept any systemd
#    minute-repeat form (*:0/N) so tuning the interval doesn't break the test,
#    but reject an hour-or-worse gap.
has '^OnCalendar=\*:0?/[0-9]{1,2}$' "$TMP/cadence-unclaimed.conf"
check "an unclaimed Pi repeats every N minutes (*:0/N)" $rc

interval="$(sed -nE 's|^OnCalendar=\*:0?/([0-9]+)$|\1|p' "$TMP/cadence-unclaimed.conf")"
[ -n "$interval" ] && [ "$interval" -le 15 ] && rc=0 || rc=1
check "that repeat is <= 15 min (got: ${interval:-none})" $rc

# 4. Jitter must not swallow the fast cadence. The pi-gen image ships
#    RandomizedDelaySec=55min, which is most of why a fresh Pi took ~an hour to
#    appear even when everything worked; a fast OnCalendar with a big delay
#    would reproduce exactly that.
delay="$(sed -nE 's|^RandomizedDelaySec=(.*)$|\1|p' "$TMP/cadence-unclaimed.conf")"
case "$delay" in
  *min) mins="${delay%min}" ;;
  *s)   mins=0 ;;
  *)    mins=999 ;;
esac
[ "$mins" -le 5 ] 2>/dev/null && rc=0 || rc=1
check "unclaimed jitter is <= 5 min (got: ${delay:-none})" $rc

# 5. Rule 2 (see CLAUDE.md): systemd ORs triggers, so the image's baked
#    OnUnitActiveSec=1h must be cleared or it keeps firing alongside ours.
#    Required in BOTH branches.
for f in claimed unclaimed; do
  has '^OnUnitActiveSec=\s*$' "$TMP/cadence-$f.conf"
  check "the $f drop-in clears the baked OnUnitActiveSec" $rc
  has '^OnCalendar=\s*$' "$TMP/cadence-$f.conf"
  check "the $f drop-in clears the baked OnCalendar before setting its own" $rc
done

# 6. The branch is driven by the SAME "am I claimed" expression the canary and
#    per-site-pin tasks use. Two tests of claimed-ness that can disagree is the
#    seam class this repo keeps getting bitten by.
hasF "site_slug | default('') | length > 0" "$REPO/roles/base/tasks/main.yml"
check "the cadence branch reuses site-identity's claimed-ness expression" $rc

# 7. Hand both OnCalendar values to the REAL systemd parser.
#
#    Everything above is a regex over a string we wrote — it proves the template
#    emitted what we meant, not that systemd accepts it. Those are different
#    claims, and the gap is the whole reason the CI grep this test replaced was
#    insufficient. An unparseable OnCalendar is the worst outcome available here:
#    systemd drops the trigger, the drop-in has already cleared OnUnitActiveSec,
#    and the Pi is left firing on OnBootSec alone — one attempt at boot, then
#    never again. Strictly worse than the daily schedule this change replaces.
#
#    Linux-only (systemd-analyze doesn't exist on darwin), so it SKIPS locally on
#    a Mac and runs for real on CI's ubuntu runner.
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in claimed unclaimed; do
    cal="$(sed -nE 's|^OnCalendar=(.+)$|\1|p' "$TMP/cadence-$f.conf")"
    systemd-analyze calendar "$cal" >/dev/null 2>&1 && rc=0 || rc=1
    check "systemd parses the $f OnCalendar ($cal)" $rc
  done
else
  echo "  skip — systemd-analyze not on this host (runs on CI); OnCalendar not parser-checked"
fi

exit $fail
