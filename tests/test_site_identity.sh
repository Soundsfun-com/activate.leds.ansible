#!/usr/bin/env bash
#
# Proves the site-identity role actually resolves per-site config.
#
# This exists because the thing it tests was broken for weeks in a way that
# LOOKED fine: the dashboard wrote per-site pins, Ansible ran green, and the
# values never reached a Pi. Nothing failed — the config was simply read by
# nobody. So this test asserts effective VALUES on a real ansible-playbook run,
# not that files exist or that YAML parses.
#
# It runs the real role against a sandbox copy of the real inventory, driving
# the same code path ansible-pull uses on a Pi.
#
# Usage:  ansible/tests/test_site_identity.sh
# Needs:  ansible-playbook on PATH (pip install ansible-core)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v ansible-playbook >/dev/null || {
  echo "SKIP: ansible-playbook not installed (pip install ansible-core)" >&2
  exit 127
}

FLEET_VERSION="$(grep -E '^cloudflared_version:' "$REPO/inventory/group_vars/all.yml" | awk '{print $2}')"
CANARY_VERSION="2099.9.9"
PINNED_VERSION="2011.1.1"

# ── sandbox: real role + real playbook wiring, controlled vars ───────────────
mkdir -p "$TMP/inventory/group_vars" "$TMP/inventory/host_vars" "$TMP/playbooks"
cp -R "$REPO/roles" "$TMP/roles"
cp "$REPO/inventory/group_vars/all.yml" "$TMP/inventory/group_vars/all.yml"
cat > "$TMP/inventory/group_vars/canary.yml" <<EOF
cloudflared_version: $CANARY_VERSION
EOF
cat > "$TMP/inventory/host_vars/pinned-store.yml" <<EOF
cloudflared_version: $PINNED_VERSION
EOF
cat > "$TMP/inventory/hosts.yml" <<'EOF'
all:
  children:
    site_agents:
      hosts:
EOF
cat > "$TMP/ansible.cfg" <<'EOF'
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
EOF

# Mirrors playbooks/site.yml: site-identity first, then anything that consumes
# the resolved vars. Prints the effective value in a greppable form.
cat > "$TMP/playbooks/probe.yml" <<'EOF'
- hosts: localhost
  connection: local
  gather_facts: no
  roles:
    - role: site-identity
  tasks:
    - debug:
        msg: "RESOLVED slug=[{{ site_slug | default('') }}] cloudflared=[{{ cloudflared_version }}]"
EOF

run_case() {  # run_case <label> <slug-or-empty> <canary_sites-json>
  local label="$1" slug="$2" canary="$3" cfg="$TMP/agent-$1.toml"
  if [[ -n "$slug" ]]; then
    printf '[cloud]\napi_base = "https://example.invalid"\nsite_slug = "%s"\nbearer_token = "x"\n' "$slug" > "$cfg"
  else
    cfg="$TMP/does-not-exist.toml"   # unclaimed Pi: no agent.toml at all
  fi
  ( cd "$TMP" && ansible-playbook playbooks/probe.yml \
      -e "agent_config_path=$cfg" \
      -e "site_vars_dir=$TMP/inventory" \
      -e "canary_sites=$canary" 2>&1 ) | grep -o 'RESOLVED slug=\[[^]]*\] cloudflared=\[[^]]*\]'
}

pass=0; fail=0
check() {  # check <label> <expected> <actual>
  if [[ "$3" == "$2" ]]; then
    printf '  ✓ %s\n' "$1"; pass=$((pass+1))
  else
    printf '  ✗ %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

echo "site-identity: per-site config resolution"

# 1. Ordinary store: fleet default, nothing layered on.
got="$(run_case plain plain-store '[]')"
check "a plain store gets the fleet version" \
      "RESOLVED slug=[plain-store] cloudflared=[$FLEET_VERSION]" "$got"

# 2. Canary member: canary value beats the fleet default. THE ROLLOUT CASE.
got="$(run_case canary canary-store '["canary-store"]')"
check "a canary store gets the canary version" \
      "RESOLVED slug=[canary-store] cloudflared=[$CANARY_VERSION]" "$got"

# 3. Non-member while a canary is active: must NOT be dragged along. This is
#    the whole point of staged rollout — blast radius of one store.
got="$(run_case bystander plain-store '["canary-store"]')"
check "a non-canary store is unaffected by an active canary" \
      "RESOLVED slug=[plain-store] cloudflared=[$FLEET_VERSION]" "$got"

# 4. Per-site pin beats the fleet default (hold a store back / roll it back).
got="$(run_case pinned pinned-store '[]')"
check "a pinned store gets its pin" \
      "RESOLVED slug=[pinned-store] cloudflared=[$PINNED_VERSION]" "$got"

# 5. Precedence: pin beats canary when a store is both.
got="$(run_case both pinned-store '["pinned-store"]')"
check "a per-site pin outranks canary" \
      "RESOLVED slug=[pinned-store] cloudflared=[$PINNED_VERSION]" "$got"

# 6. Unclaimed Pi (imaged, never assigned): no slug, still converges on fleet
#    defaults rather than failing the run.
got="$(run_case unclaimed '' '[]')"
check "an unclaimed Pi falls back to fleet defaults" \
      "RESOLVED slug=[] cloudflared=[$FLEET_VERSION]" "$got"

echo
if (( fail )); then
  echo "FAILED: $fail of $((pass+fail))"
  exit 1
fi
echo "ok: $pass/$pass"
