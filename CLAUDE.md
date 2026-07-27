# Activate fleet config — working notes

What version of what runs on each store's Raspberry Pi. Every Pi runs
`ansible-pull` against this repo at **02:00 local, once a day** (plus ~5 min
after boot). Same-day pushes go through the dashboard's "Update all agents"
button.

This repo is small and boring on purpose, and it has produced three
production-affecting bugs in a week — every one of them by **doing nothing
silently**. Read the two rules below before changing anything.

## Rule 1 — vars live under `inventory/`, never the repo root

Ansible resolves `group_vars/` and `host_vars/` relative to the **inventory
file** or the **playbook**. `ansible.cfg` points at `inventory/28-stores.yml`,
so the only paths that load are `inventory/group_vars/` and
`inventory/host_vars/`.

They sat at the repo root for weeks. Nothing loaded them, roles fell back to
their own defaults, those defaults happened to match what was installed, every
task was skipped, and each run reported success while the fleet stayed on the
version baked into the Pi image.

Guards: the `inventory_vars_loaded` sentinel (asserted first in `site.yml`), and
a CI check that the root dirs don't come back. **Never give a version pin a role
default** — an unloaded pin must fail the run, not silently reuse a stale value.

## Rule 2 — the image bakes systemd triggers, and systemd ORs them

`activate-ansible-pull.timer` ships in the Pi image with `OnBootSec=5min` +
`OnUnitActiveSec=1h`. A drop-in that sets `OnCalendar` **without** an empty
`OnUnitActiveSec=` leaves the hourly repeat running, so the new schedule looks
ignored. Same trap for any baked value.

Also: the inventory FILENAME is baked into that unit (`--inventory
inventory/28-stores.yml`). Renaming it breaks convergence on every Pi until
re-flash — which is why a file containing zero hosts is still called
`28-stores.yml`.

## Rule 3 — patching has two clocks, and both must be set

`auto_apply_security_patches: true` (2026-07-27) makes unattended-upgrades
actually INSTALL Debian security patches, not just download them. Two schedules
have to agree or the policy is a fiction:

- **When it upgrades** — Debian's `apt-daily-upgrade.timer` fires at 06:00
  ±60 min out of the box. The security role ships a drop-in pinning it to the
  maintenance-window start. Same OR-ing trap as Rule 2: clear `OnCalendar=`
  first.
- **When it reboots** — `Automatic-Reboot-Time` must be the window END. Set it
  to the start (where the upgrade also begins) and the time has already passed
  by the time the upgrade finishes, so a kernel patch waits for the next night.

`tests/test_patch_window.sh` renders the real templates and asserts both. It
was written after getting both wrong in one sitting; ansible reports green
either way.

## How a Pi knows which store it is

It doesn't, by default: every Pi converges as `hosts: localhost`, i.e. Ansible's
implicit localhost, which matches no inventory host and belongs to no group. So
only `group_vars/all.yml` reaches it.

The `site-identity` role (first in `site.yml`) fixes that by reading
`site_slug` from `/etc/activate-wled/agent.toml`, then layering:

    all.yml  <  canary.yml (if slug ∈ canary_sites)  <  host_vars/<slug>.yml

Per-site pins and canary rollout depend entirely on it. Don't reorder it.

`site_timezone` (which decides when 2am is) defaults to `America/New_York` for
every Pi — a store outside Eastern needs it set in its `host_vars/<slug>.yml`.

## Verifying

    tests/test_site_identity.sh          # needs: pip install ansible-core
    ansible-playbook --syntax-check playbooks/site.yml

CI runs both plus the guards above. `inventory/group_vars/all.yml` is
**machine-managed** — the dashboard rewrites it and erases comments; put
explanation here instead.
