#!/usr/bin/env bash
#
# Proves each claimed Pi resolves to ACT-LED-Pi-<Store>.
#
# Asserts the RESOLVED VALUE, not that the pattern string exists — the same
# reason test_site_identity.sh exists. A hostname rule that renders to the
# wrong thing (or to nothing) fails silently: ansible reports green, and the
# only symptom is a router client list full of identically-named Pis.
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
  echo "::error::no activate_hostname_pattern in canary.yml or all.yml — per-store Pi naming is disabled fleet-wide" >&2
  exit 1
}

grep -q 'site_hostname_slug' <<<"$PATTERN" || {
  echo "::error::activate_hostname_pattern doesn't reference site_hostname_slug, so every Pi in the fleet would resolve to the SAME name: $PATTERN" >&2
  exit 1
}

# A hostname may contain only letters, digits and hyphens. This is the check
# that matters most in this file: the requested wording was
# "ACT-LED Pi-[Alpharetta]", and the space and brackets in it are invalid —
# `hostnamectl` rejects them, which aborts the play in `base` and leaves the Pi
# running but no longer updating. Assert the shape of the pattern itself so a
# future reword can't reintroduce one.
BAD="$(printf '%s' "$PATTERN" | sed 's/{{ *site_hostname_slug *}}//' | tr -d 'A-Za-z0-9-')"
[[ -z "$BAD" ]] && {
  :
} || {
  echo "::error::activate_hostname_pattern contains characters that are not valid in a hostname ('$BAD') — only letters, digits and hyphens are safe: $PATTERN" >&2
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

# Imports the real task file the base role uses. `desired_hostname` is left
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
  ( cd "$TMP" && ansible-playbook playbooks/probe.yml \
      -e "site_slug=$slug" \
      -e "activate_hostname_pattern=$pattern" \
      "$@" 2>&1 ) | grep -o 'RESOLVED name=\[[^]]*\]'
}

pass=0; fail=0
check() {  # check <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else
    printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

echo "base: per-store Pi hostname resolution (pattern: $PATTERN)"

# 1. The ordinary case — a single-word store. Slugs are stored lowercase, and
#    the name shows the store the way people write it.
got="$(run_case alpharetta "$PATTERN")"
check "a store resolves to its own name, capitalized" \
      "RESOLVED name=[$(render Alpharetta)]" "$got"

# 2. Multi-word store: EVERY word capitalized, hyphen kept as the separator.
#    `american-dream` must not come out as `American-dream` (only the first
#    word title-cased) — a real failure mode of Jinja's `title` if the slug
#    isn't split on hyphens first.
got="$(run_case american-dream "$PATTERN")"
check "every word of a multi-word store is capitalized" \
      "RESOLVED name=[$(render American-Dream)]" "$got"

# 3. Unclaimed Pi: imaged, never assigned to a store. Must keep the image's
#    name rather than resolving to a half-rendered ACT-LED-Pi-.
got="$(run_case "" "$PATTERN")"
check "an unclaimed Pi is left alone" \
      "RESOLVED name=[(unchanged)]" "$got"

# 4. Pattern disabled (the role default) — the pre-rollout state, and the
#    revert path if a store's router chokes on the name.
got="$(run_case alpharetta "")"
check "an empty pattern renames nothing" \
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
