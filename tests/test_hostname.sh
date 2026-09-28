#!/usr/bin/env bash
#
# Proves the two-name convention: a claimed Pi resolves to ACT-LED-Pi, an
# unclaimed one to ACT-LED-Pi-Unclaimed (both read from the repo, not
# hardcoded here).
#
# Asserts the RESOLVED VALUE, not that the pattern string exists — the same
# reason test_site_identity.sh exists. A hostname rule that renders to the
# wrong thing (or to nothing) fails silently: ansible reports green, and the
# only symptom is a Pi the store's Activate server can't find.
#
# Runs the real base-role logic (roles/base/tasks/resolve-hostname.yml), which
# is split out of main.yml precisely so this can run without root or systemd —
# it computes the name, it does not apply it.
#
# Usage:  ansible/tests/test_hostname.sh
# Needs:  ansible-playbook on PATH (pip install ansible-core)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v ansible-playbook >/dev/null || {
  echo "SKIP: ansible-playbook not installed (pip install ansible-core)" >&2
  exit 127
}

# The pattern under test is read from the repo, not hardcoded here, so
# promoting it from canary.yml to all.yml, or rewording the prefix, doesn't
# need this file edited — it just has to keep resolving.
PATTERN="$(grep -hE '^activate_hostname_pattern:' \
             "$REPO/inventory/group_vars/canary.yml" \
             "$REPO/inventory/group_vars/all.yml" 2>/dev/null \
           | head -1 | cut -d: -f2- | sed 's/^ *//; s/^"//; s/"$//')"

[[ -n "$PATTERN" ]] || {
  echo "::error::no activate_hostname_pattern in canary.yml or all.yml — Pi naming is disabled fleet-wide" >&2
  exit 1
}

# The unclaimed name comes from the role default and MUST equal what the image
# bakes, or every freshly-flashed Pi is renamed on its first pull.
UNCLAIMED="$(grep -hE '^activate_unclaimed_hostname:' "$REPO/roles/base/defaults/main.yml" \
             | head -1 | cut -d: -f2- | sed 's/^ *//; s/^"//; s/"$//')"
[[ -n "$UNCLAIMED" ]] || {
  echo "::error::no activate_unclaimed_hostname in roles/base/defaults/main.yml" >&2
  exit 1
}

# NOTE: a pattern WITHOUT {{ site_hostname_slug }} is deliberate since
# 2026-09-28 — one lights Pi per store, one name everywhere, so the store's
# Activate server can address its webhooks the same way at every location.

# A hostname may contain only letters, digits and hyphens. This is the check
# that matters most in this file: the requested wording was
# "ACT-LED Pi-[Alpharetta]", and the space and brackets in it are invalid —
# `hostnamectl` rejects them, which aborts the play in `base` and leaves the Pi
# running but no longer updating. Assert the shape of the pattern itself so a
# future reword can't reintroduce one.
for NAME in "$PATTERN" "$UNCLAIMED"; do
  BAD="$(printf '%s' "$NAME" | sed 's/{{ *site_hostname_slug *}}//' | tr -d 'A-Za-z0-9-')"
  [[ -z "$BAD" ]] || {
    echo "::error::hostname '$NAME' contains characters that are not valid in a hostname ('$BAD') — only letters, digits and hyphens are safe" >&2
    exit 1
  }
done
[[ "$PATTERN" != "$UNCLAIMED" ]] || {
  echo "::error::claimed and unclaimed Pis resolve to the same name ($PATTERN) — an unassigned Pi would be indistinguishable from a store's live one" >&2
  exit 1
}

# Expected names are RENDERED from the repo's own pattern rather than spelled
# out here, so rewording the prefix doesn't turn CI red for an unrelated reason.
render() { printf '%s' "$PATTERN" | sed "s/{{ *site_hostname_slug *}}/$1/"; }

mkdir -p "$TMP/playbooks"
cp -R "$REPO/roles" "$TMP/roles"
cat > "$TMP/ansible.cfg" <<'EOF'
[defaults]
roles_path = roles
EOF

# Imports the real task file the base role uses. It runs outside the role, so
# role defaults don't load — the unclaimed name is passed in from the defaults
# file that ships it, exactly as the pattern is passed from all.yml.
# `desired_hostname` is left
# undefined unless a case passes one in, mirroring host_vars/<slug>.yml.
cat > "$TMP/playbooks/probe.yml" <<'EOF'
- hosts: localhost
  connection: local
  gather_facts: no
  tasks:
    - import_tasks: ../roles/base/tasks/resolve-hostname.yml
    - debug:
        msg: "RESOLVED name=[{{ desired_hostname | default('(unchanged)') }}]"
EOF

run_case() {  # run_case <slug> <pattern> [extra -e args...]
  local slug="$1" pattern="$2"; shift 2
  # `|| true` matters: under `set -euo pipefail` a grep that matches nothing
  # fails the pipeline, which fails the `got="$(run_case ...)"` assignment,
  # which aborts the whole script with no output. An unmatched probe then looks
  # like a crash instead of a failing assertion. Let it return empty and let
  # `check` report it. (This is the trap that hid the broken assertion in
  # tests/test_patch_window.sh from CI for two weeks.)
  ( cd "$TMP" && ansible-playbook playbooks/probe.yml \
      -e "site_slug=$slug" \
      -e "activate_hostname_pattern=$pattern" \
      -e "activate_unclaimed_hostname=$UNCLAIMED" \
      "$@" 2>&1 ) | grep -o 'RESOLVED name=\[[^]]*\]' || true
}

pass=0; fail=0
check() {  # check <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else
    printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

echo "base: Pi hostname resolution (claimed: $PATTERN · unclaimed: $UNCLAIMED)"

# 1. A claimed store Pi gets the fleet name.
got="$(run_case alpharetta "$PATTERN")"
check "a claimed Pi gets the claimed name" \
      "RESOLVED name=[$(render Alpharetta)]" "$got"

# 2. Multi-word store. With a fixed pattern this proves the slug does NOT leak
#    into the name; with a per-store pattern it proves every word is
#    capitalized (`american-dream` → `American-Dream`, not `American-dream`).
got="$(run_case american-dream "$PATTERN")"
check "a multi-word store resolves per the pattern" \
      "RESOLVED name=[$(render American-Dream)]" "$got"

# 2b. Pin the CURRENT convention: the fleet pattern is store-agnostic, so two
#     different stores resolve to the same name. Going back to per-store names
#     should be a deliberate edit of this case, not a silent drift.
a_name="$(run_case alpharetta "$PATTERN")"; b_name="$(run_case town-square "$PATTERN")"
check "every claimed store resolves to the same name" "$a_name" "$b_name"

# 3. Unclaimed Pi (imaged, never assigned — or un-enrolled): the unclaimed
#    name, even if it booted from an older image as activate-led-controller-pi.
got="$(run_case "" "$PATTERN")"
check "an unclaimed Pi gets the unclaimed name" \
      "RESOLVED name=[$UNCLAIMED]" "$got"

# 4. Pattern disabled (the role default) — the revert path. Renames NOTHING,
#    claimed or unclaimed.
got="$(run_case alpharetta "")"
check "an empty pattern leaves a claimed Pi alone" \
      "RESOLVED name=[(unchanged)]" "$got"
got="$(run_case "" "")"
check "an empty pattern leaves an unclaimed Pi alone" \
      "RESOLVED name=[(unchanged)]" "$got"

# 5. An explicit host_vars pin outranks the pattern, so one store can be named
#    by hand without turning the scheme off fleet-wide.
got="$(run_case alpharetta "$PATTERN" -e "desired_hostname=named-by-hand")"
check "an explicit desired_hostname wins" \
      "RESOLVED name=[named-by-hand]" "$got"

echo
if (( fail )); then
  echo "FAILED: $fail failed, $pass passed"; exit 1
fi
echo "OK: $pass passed"
