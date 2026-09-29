#!/usr/bin/env bash
#
# Proves when a Pi re-announces its hostname to the store router.
#
# The router only learns a name from a DHCP request, so after a rename the
# base role reconnects the network once (roles/base/files/activate-dhcp-reannounce).
# The failure modes worth guarding are both silent: never firing (the store's
# DNS keeps the old name and webhooks to ACT-LED-Pi go nowhere), and firing on
# every pull (every store's network drops every night for nothing).
#
# Runs the real decision file with a temporary state file, plus a bash syntax
# check of the helper itself.
#
# Usage:  ansible/tests/test_dhcp_reannounce.sh
# Needs:  ansible-playbook on PATH (pip install ansible-core)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v ansible-playbook >/dev/null || {
  echo "SKIP: ansible-playbook not installed (pip install ansible-core)" >&2
  exit 127
}

bash -n "$REPO/roles/base/files/activate-dhcp-reannounce" || {
  echo "::error::roles/base/files/activate-dhcp-reannounce has a bash syntax error" >&2
  exit 1
}

cat > "$TMP/probe.yml" <<PROBE
- hosts: localhost
  connection: local
  gather_facts: no
  vars:
    ansible_hostname: ACT-LED-Pi
  tasks:
    - import_tasks: $REPO/roles/base/tasks/reannounce-decision.yml
    - debug:
        msg: "DECISION needed=[{{ hostname_reannounce_needed | bool }}]"
PROBE

run_case() {  # run_case <state-file-content-or-ABSENT> [extra -e args...]
  local content="$1"; shift
  local state="$TMP/state"
  rm -f "$state"
  [[ "$content" == "ABSENT" ]] || printf '%s\n' "$content" > "$state"
  # `|| true`: see test_hostname.sh — an unmatched grep must fail the check,
  # not abort the script silently.
  ansible-playbook "$TMP/probe.yml" -e "activate_dhcp_state_file=$state" "$@" \
    </dev/null 2>&1 | grep -o 'DECISION needed=\[[^]]*\]' || true
}

pass=0; fail=0
check() {
  if [[ "$3" == "$2" ]]; then printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "base: hostname re-announce to the store router"

check "a Pi that has never announced re-announces once" \
      "DECISION needed=[True]" "$(run_case ABSENT)"
check "a Pi whose router already has this name does nothing" \
      "DECISION needed=[False]" "$(run_case ACT-LED-Pi)"
check "a Pi renamed since its last announce re-announces" \
      "DECISION needed=[True]" "$(run_case ACT-LED-Pi-Unclaimed)"
check "the name ansible is about to set wins over the current one" \
      "DECISION needed=[False]" "$(run_case ACT-LED-Pi-Unclaimed -e desired_hostname=ACT-LED-Pi-Unclaimed)"
check "the kill switch stops it" \
      "DECISION needed=[False]" "$(run_case ABSENT -e activate_dhcp_reannounce=false)"

# ── The helper itself, against fake network tools ───────────────────────────
# What must hold on a real Pi at 02:00: skip without touching anything when the
# network isn't NetworkManager's; record the name BEFORE bouncing (so it can
# never loop); reboot only when the network fails to come back.
AWK="$(command -v awk)"; BASH_BIN="$(command -v bash)"
helper() {  # helper <scenario>  → prints "<state-file-content>|<reboot?>"
  local sc="$1" bin="$TMP/bin-$1" st="$TMP/state-$1"
  rm -rf "$bin" "$st"; mkdir -p "$bin"; ln -s "$AWK" "$bin/awk"
  printf '#!%s\necho ACT-LED-Pi\n' "$BASH_BIN" > "$bin/hostnamectl"
  printf '#!%s\nexit 0\n' "$BASH_BIN" > "$bin/logger"
  printf '#!%s\necho "$*" >> %s\n' "$BASH_BIN" "$TMP/systemctl-$sc" > "$bin/systemctl"
  if [[ "$sc" == no-route ]]; then printf '#!%s\nexit 0\n' "$BASH_BIN" > "$bin/ip"
  else printf '#!%s\necho "default via 192.168.2.1 dev eth0 proto dhcp"\n' "$BASH_BIN" > "$bin/ip"; fi
  if [[ "$sc" != no-nmcli ]]; then
    printf '#!%s\ncase "$*" in *"device show"*) echo "Wired connection 1";; *"connection up"*) exit %s;; esac\n' \
      "$BASH_BIN" "$([[ $sc == net-fails ]] && echo 4 || echo 0)" > "$bin/nmcli"
    printf '#!%s\nexit 0\n' "$BASH_BIN" > "$bin/nm-online"
  fi
  chmod +x "$bin"/*
  rm -f "$TMP/systemctl-$sc"
  PATH="$bin" ACTIVATE_DHCP_STATE_FILE="$st" "$BASH_BIN" "$REPO/roles/base/files/activate-dhcp-reannounce" >/dev/null 2>&1 || true
  printf '%s|%s' "$(cat "$st" 2>/dev/null || echo NONE)" "$(grep -q reboot "$TMP/systemctl-$sc" 2>/dev/null && echo reboot || echo no-reboot)"
}
check "helper: no NetworkManager → records nothing, never reboots" "NONE|no-reboot" "$(helper no-nmcli)"
check "helper: no default route → records nothing, never reboots"   "NONE|no-reboot" "$(helper no-route)"
check "helper: reconnect works → name recorded, no reboot"          "ACT-LED-Pi|no-reboot" "$(helper ok)"
check "helper: network stays down → name recorded FIRST, then reboot" "ACT-LED-Pi|reboot" "$(helper net-fails)"

echo
if (( fail )); then echo "FAILED: $fail failed, $pass passed"; exit 1; fi
echo "OK: $pass passed"
