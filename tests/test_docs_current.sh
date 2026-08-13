#!/usr/bin/env bash
#
# Proves the prose in README.md / CLAUDE.md still describes the config that
# actually ships.
#
# Why this test exists:
#
#   On 2026-08-13 the README still said every Pi runs ansible-pull "hourly" and
#   that a change reaches the fleet "within ~1h". Both had been false since the
#   Rule 4 rework three weeks earlier: a claimed store converges at 02:00 local
#   (so a revert takes up to ~24h), and only unclaimed Pis are fast. The same
#   dead sentence had also been copied into playbooks/site.yml's header, the
#   base role's defaults and its tasks — four places, one fact, none of them
#   load-bearing enough for anything to notice.
#
#   That's the repo's usual failure in a new costume: nothing errors, it just
#   quietly says the wrong thing, and the wrong thing is what a tired person
#   reads at 2am while deciding whether a bad commit has reached the stores yet.
#
# The rule this enforces: a number, version or schedule has exactly ONE home —
# the config that ships it. Docs may quote it, but a quote that stops matching
# its source fails here.
#
# Usage:  ansible/tests/test_docs_current.sh
# Needs:  nothing (pure grep — runs anywhere, unlike the render tests)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS=("$REPO/README.md" "$REPO/CLAUDE.md")

fail=0
check() {  # check <description> <condition-result>
  if [ "$2" = "0" ]; then
    echo "  ok   — $1"
  else
    echo "  FAIL — $1"
    fail=1
  fi
}

# Pull the real values out of the files that ship them, so a changed schedule is
# covered rather than restated here.
claimed_cal="$(sed -nE 's|^ansible_pull_oncalendar: *"?([^"]+)"? *$|\1|p' \
  "$REPO/inventory/group_vars/all.yml" | head -1)"
unclaimed_cal="$(sed -nE 's|^ansible_pull_unassigned_oncalendar: *"?([^"]+)"? *$|\1|p' \
  "$REPO/roles/base/defaults/main.yml" | head -1)"

echo "docs match the shipping config:"

[ -n "$claimed_cal" ] && rc=0 || rc=1
check "found the claimed cadence in group_vars/all.yml (got: ${claimed_cal:-none})" $rc
[ -n "$unclaimed_cal" ] && rc=0 || rc=1
check "found the unclaimed cadence in base defaults (got: ${unclaimed_cal:-none})" $rc
[ "$fail" = "1" ] && exit 1

# 1. No doc may describe the pull cadence in the present tense as hourly, or
#    promise fleet-wide convergence inside an hour. This is the exact sentence
#    that sat wrong for three weeks.
#
#    History must stay writable, or the rule that says "explain the incident
#    here" fights the test that says "don't write that phrase" — Rule 6 itself
#    tripped this on its first run for quoting the dead sentence it exists to
#    describe. The distinction drawn is citation vs. claim: text inside double
#    quotes is stripped before matching, so `said Pis pull "hourly"` is fine
#    while a bare `Pis pull hourly` fails. Cite it, don't assert it.
for doc in "${DOCS[@]}"; do
  name="$(basename "$doc")"
  sed 's/"[^"]*"//g' "$doc" \
    | grep -niE 'runs?[a-z ]* hourly|pulls? hourly|every hour\b|within ~?1 ?h\b|converges? within 1h' \
      >/dev/null && rc=1 || rc=0
  check "$name doesn't claim an hourly pull / 1h convergence" $rc
done

# 2. The claimed-store time quoted in prose must be the one that ships. Compare
#    on the HH:MM, which is the form a human writes ("02:00 local").
hhmm="$(printf '%s' "$claimed_cal" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)"
for doc in "${DOCS[@]}"; do
  name="$(basename "$doc")"
  grep -qF "$hhmm" "$doc" && rc=0 || rc=1
  check "$name quotes the real claimed-store time ($hhmm)" $rc
done

# 3. Same for the unclaimed repeat: `*:0/10` must be described as ~10 min. Docs
#    may phrase it "every ~10 min" or "10min"; both contain the number next to
#    "min", which is what we look for.
mins="$(printf '%s' "$unclaimed_cal" | sed -nE 's|^\*:0?/([0-9]+)$|\1|p')"
if [ -n "$mins" ]; then
  for doc in "${DOCS[@]}"; do
    name="$(basename "$doc")"
    grep -qiE "${mins} ?min" "$doc" && rc=0 || rc=1
    check "$name quotes the real unclaimed repeat (~${mins} min)" $rc
  done
else
  echo "  skip — unclaimed cadence '$unclaimed_cal' isn't a *:0/N repeat; nothing to cross-check"
fi

# 4. CROSS-REPO, best-effort. The baked timer lives in the dashboard repo, so
#    this repo's CI genuinely cannot see it — that half of the seam is held by
#    the one-home rule and a human, not by this check. When both repos ARE
#    checked out side by side (a dev machine), verify the two numbers the docs
#    quote from it, and Rule 4's invariant that the baked repeat is at least as
#    fast as the unclaimed cadence.
BAKED="$REPO/../dashboard/infra/pi-image/stage3-activate/03-ansible-pull/files/activate-ansible-pull.timer"
if [ -f "$BAKED" ]; then
  boot="$(sed -nE 's|^OnBootSec=(.+)$|\1|p' "$BAKED" | head -1)"
  active="$(sed -nE 's|^OnUnitActiveSec=(.+)$|\1|p' "$BAKED" | head -1)"

  for doc in "${DOCS[@]}"; do
    name="$(basename "$doc")"
    grep -qF "OnBootSec=$boot" "$doc" && rc=0 || rc=1
    check "$name quotes the baked OnBootSec ($boot)" $rc
    grep -qF "OnUnitActiveSec=$active" "$doc" && rc=0 || rc=1
    check "$name quotes the baked OnUnitActiveSec ($active)" $rc
  done

  # Rule 4: the baked repeat is a never-yet-converged Pi's ONLY schedule. If it
  # were slower than the unclaimed cadence, a freshly-flashed box would take
  # longer to reach the Assign tab than the role intends — the original bug.
  baked_mins="$(printf '%s' "$active" | sed -nE 's|^([0-9]+)min$|\1|p')"
  if [ -n "$baked_mins" ] && [ -n "$mins" ]; then
    [ "$baked_mins" -le "$mins" ] && rc=0 || rc=1
    check "baked repeat (${baked_mins}min) is at least as fast as unclaimed (${mins}min)" $rc
  fi
else
  echo "  skip — ../dashboard not checked out; baked-timer values not cross-checked"
  echo "         (this is the cross-repo blind spot: only the one-home rule covers it)"
fi

exit $fail
