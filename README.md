# activate.leds.ansible

Fleet-sync configuration for the Activate WLED dashboard's Raspberry Pi fleet.

Every site Pi and portable flasher runs `ansible-pull` hourly against this repo, converging its state to whatever the `main` branch declares. This is the **config plane** of the fleet — the [Cloudflare Tunnel](https://github.com/Soundsfun-com/activate.leds.dashboard) handles the control plane.

> Architecture: see [`PLAN.md` §7.3.4](https://github.com/Soundsfun-com/activate.leds.dashboard/blob/main/PLAN.md) in the dashboard repo for the full Ansible fleet-sync ADR.

## Why this repo is public

This repo contains **only configuration patterns and conventions** — no credentials, no internal IPs, no topology that grants access to anything. The security boundary for the fleet is enforced elsewhere (Cloudflare Access, outbound-only tunnels, per-Pi bearer tokens). Making the repo public means:

- Pis clone over plain HTTPS with no auth — no shared deploy key to leak or rotate
- The convention is auditable in the open ("no secrets in git" is enforced by GitHub's push protection)
- Anyone in the org can review fleet-config changes without repo invitations

See [`SECURITY.md`](./SECURITY.md) for the full "what's not in this repo" list and where secrets actually live.

## What lives here

```
.
├── inventory/                     # ALL vars live under here — see the note below
│   ├── 28-stores.yml              # ZERO hosts despite the name — see the file's header.
│   │                              # Name is baked into every Pi's systemd unit; do NOT rename.
│   ├── group_vars/
│   │   ├── all.yml                # fleet-wide defaults + the inventory_vars_loaded sentinel
│   │   └── canary.yml             # canary-group overrides (staged-rollout source)
│   └── host_vars/
│       └── <slug>.yml             # ⚠️ NON-FUNCTIONAL today — the play runs as `localhost`,
│                                  # so these are written by the dashboard and never read
├── playbooks/
│   └── site.yml                   # the ansible-pull target — runs every hour on every Pi
└── roles/
    ├── base/                      # OS hardening, hostname, timezone, logrotate
    ├── cloudflared/               # tunnel config + version pinning
    ├── activate-agent/            # clones agent code from dashboard repo, manages venv + systemd unit
    ├── udev-rules/                # ttyUSB*/ttyACM* permissions (matches pi-gen image bake)
    └── security/                  # unattended-upgrades, fail2ban, sshd hardening
```

## How a Pi pulls this

Each Pi's image (built by [`Soundsfun-com/activate.leds.dashboard`](https://github.com/Soundsfun-com/activate.leds.dashboard)'s `infra/pi-image/`) has:

- A read-only **deploy key** for this repo at `/etc/ansible/deploy-key`
- A systemd timer `activate-ansible-pull.timer` firing hourly with a randomized 0–55 min offset (avoids fleet stampede)
- A oneshot service `activate-ansible-pull.service` that runs:
  ```
  ansible-pull \
    --url git@github.com:Soundsfun-com/activate.leds.ansible.git \
    --inventory inventory/28-stores.yml \
    --purge \
    playbooks/site.yml
  ```

A change pushed to `main` propagates to the fleet within ~1h. Bulk updates (e.g. agent version bump) happen by editing `inventory/group_vars/all.yml` and pushing.

> **group_vars/host_vars MUST stay under `inventory/`.** Ansible resolves them relative to the inventory file or the playbook — never the repo root. They lived at the repo root until 2026-07-26, so nothing loaded them: roles fell back to their own defaults, those defaults matched what was already installed, every task was skipped, and each hourly run reported success while the fleet stayed on the version baked into the Pi image. `inventory/group_vars/all.yml` now carries an `inventory_vars_loaded` sentinel that `site.yml` asserts in pre_tasks, so a repeat fails loudly on the first Pi instead of hiding for weeks.

## Staged rollouts

The dashboard's `/firmware` Edge Devices tab (forthcoming) drives staged rollouts by editing this repo:

1. **Canary**: change goes into `inventory/group_vars/canary.yml` first; only Pis in the `canary` inventory group pick it up. Soak ~24h.
2. **All**: promote to `inventory/group_vars/all.yml`. Fleet converges within 1h.
3. **Rollback**: `git revert` the offending commit. Fleet converges back within 1h. No special tooling.

## Sibling repos

| Repo | Role |
|---|---|
| [`Soundsfun-com/activate.leds.dashboard`](https://github.com/Soundsfun-com/activate.leds.dashboard) | Next.js dashboard (control plane), Python agent code, Pi image config |
| **`Soundsfun-com/activate.leds.ansible`** (this) | Fleet-sync state convergence (config plane) |

## Local development

```bash
# Lint the playbook
ansible-lint playbooks/site.yml

# Syntax check
ansible-playbook --syntax-check playbooks/site.yml

# Dry-run against a test inventory
ansible-playbook -i inventory/test.yml --check playbooks/site.yml
```
