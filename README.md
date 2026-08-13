# activate.leds.ansible

Fleet-sync configuration for the Activate WLED dashboard's Raspberry Pi fleet.

Every site Pi and portable flasher runs `ansible-pull` against this repo on a schedule, converging its state to whatever the `main` branch declares. This is the **config plane** of the fleet — the [Cloudflare Tunnel](https://github.com/Soundsfun-com/activate.leds.dashboard) handles the control plane.

> **Working notes live in [`CLAUDE.md`](./CLAUDE.md), not here.** That file carries the five rules that keep this repo from silently doing nothing, plus the hostname rollout, the canary workflow, and the Warehouse pin. This README is the orientation doc: what the repo is, how a Pi consumes it, how a change reaches the fleet. When the two disagree, `CLAUDE.md` is authoritative.

> Architecture: see [`PLAN.md` §7.3.4](https://github.com/Soundsfun-com/activate.leds.dashboard/blob/main/PLAN.md) in the dashboard repo for the full Ansible fleet-sync ADR.

## Why this repo is public

This repo contains **only configuration patterns and conventions** — no credentials, no internal IPs, no topology that grants access to anything. The security boundary for the fleet is enforced elsewhere (Cloudflare Access, outbound-only tunnels, per-Pi bearer tokens). Making the repo public means:

- Pis clone **this** repo over plain HTTPS with no auth — no shared deploy key to leak or rotate. (The private *agent* repo is a separate clone and does use a baked deploy key — see below.)
- The convention is auditable in the open ("no secrets in git" is enforced by GitHub's push protection)
- Anyone in the org can review fleet-config changes without repo invitations

See [`SECURITY.md`](./SECURITY.md) for the full "what's not in this repo" list and where secrets actually live.

## What lives here

```
.
├── CLAUDE.md                      # the five rules + rollout history — read before changing anything
├── inventory/                     # ALL vars live under here — see Rule 1
│   ├── 28-stores.yml              # ZERO hosts despite the name — see the file's header.
│   │                              # Name is baked into every Pi's systemd unit; do NOT rename.
│   ├── group_vars/
│   │   ├── all.yml                # fleet-wide defaults + the inventory_vars_loaded sentinel
│   │   └── canary.yml             # canary overrides — applies to slugs in `canary_sites`
│   └── host_vars/
│       └── <slug>.yml             # per-store overrides — LIVE since the site-identity role
│                                  # (the play runs as localhost, so site-identity hand-loads these)
├── playbooks/
│   └── site.yml                   # the ansible-pull target
├── roles/
│   ├── site-identity/             # FIRST — resolves site_slug, layers canary + per-site vars
│   ├── base/                      # OS hardening, hostname, timezone, logrotate, pull cadence
│   ├── udev-rules/                # ttyUSB*/ttyACM* permissions (matches pi-gen image bake)
│   ├── security/                  # unattended-upgrades, fail2ban, sshd hardening
│   ├── activate-agent/            # clones the agent repo at the pinned ref, manages venv + systemd
│   └── cloudflared/               # tunnel config + version pinning
└── tests/                         # render-and-assert scripts; CI runs all four
```

Role order in `site.yml` is load-bearing: `site-identity` must stay first or per-site pins and canary silently revert to fleet-wide-only.

## How a Pi pulls this

Each Pi's image (built by [`Soundsfun-com/activate.leds.dashboard`](https://github.com/Soundsfun-com/activate.leds.dashboard)'s `infra/pi-image/`) ships:

- A oneshot service `activate-ansible-pull.service` that runs:
  ```
  ansible-pull \
    --url https://github.com/Soundsfun-com/activate.leds.ansible.git \
    --directory /var/lib/activate-ansible \
    --inventory inventory/28-stores.yml \
    --purge \
    playbooks/site.yml
  ```
- A systemd timer `activate-ansible-pull.timer` with a deliberately impatient baked schedule (`OnBootSec=90s`, `OnUnitActiveSec=10min`, `RandomizedDelaySec=60s`). **That baked schedule governs exactly one situation: a Pi that has never completed a pull.** From the first successful pull onward, the `base` role's drop-in owns the cadence.
- A read-only deploy key at `/etc/ansible/agent-deploy-key` — for the **private agent repo**, which `activate-agent` clones over SSH. This repo itself needs no key.

### Cadence: it depends on whether the Pi is claimed

| Pi state | Converges | Why |
|---|---|---|
| **Unclaimed** (flashed, not yet assigned to a store) | every ~10 min | The image bakes the agent's virtualenv but not the agent code. Until a pull installs the agent, the Pi cannot appear on the dashboard's Assign tab at all — so cadence *is* time-to-appear for an installer. |
| **Claimed** (has a `site_slug`) | **02:00 in the store's own local time**, +0–30 min jitter, plus ~90 s after any boot | It's running the lights. Converge while the building is empty. |

`site_timezone` decides when 2 AM is; it defaults to `America/New_York`, so a store outside Eastern needs it set in its `host_vars/<slug>.yml`.

**So: a change pushed to `main` reaches a claimed store on its next 2 AM — up to ~24 h.** Same for a `git revert`. When that's too slow, use the **"Update all agents"** button on the dashboard's [Edge Pis page](https://github.com/Soundsfun-com/activate.leds.dashboard) (`/pis`), which triggers a pull now rather than waiting for the window. Do not "temporarily" speed up the fleet cadence to work around this — that widens the blast-radius window for a bad commit across all 28 stores.

Bulk version changes (e.g. an agent bump) happen by editing `inventory/group_vars/all.yml` and pushing, or via the dashboard's Firmware console, which writes the same file.

> **Everything under `inventory/` is MACHINE-MANAGED — don't put comments there.**
> The dashboard's pin/promote/canary actions round-trip `all.yml`, `canary.yml`
> and `host_vars/<slug>.yml` through `js-yaml` (`load` → mutate → `dump`), which
> has no concept of comments. Keys survive; prose is deleted without warning on
> the next button click. This has happened twice — most recently 2026-08-12,
> when a one-key canary write erased 25 lines of rollout rationale. Durable
> explanation goes in `CLAUDE.md`, in role comments, or in the CI guard.
> Recover erased prose with `git show <commit-before>:<path>`.

> **group_vars/host_vars MUST stay under `inventory/`.** Ansible resolves them relative to the inventory file or the playbook — never the repo root. They lived at the repo root until 2026-07-26, so nothing loaded them: roles fell back to their own defaults, those defaults matched what was already installed, every task was skipped, and each run reported success while the fleet stayed on the version baked into the Pi image. `inventory/group_vars/all.yml` now carries an `inventory_vars_loaded` sentinel that `site.yml` asserts in `pre_tasks`, so a repeat fails loudly on the first Pi instead of hiding for weeks. CI guards it too.

## Staged rollouts

Precedence is `all.yml` < `canary.yml` (if the Pi's slug is in `canary_sites`) < `host_vars/<slug>.yml`. The dashboard's Firmware console drives this by committing to this repo; you can also just edit and push.

1. **Canary**: put the var in `inventory/group_vars/canary.yml`. Only slugs listed in `canary_sites` (today: `warehouse`) pick it up — this is resolved by the `site-identity` role reading `site_slug` from the Pi's `agent.toml`, *not* by Ansible inventory-group matching. Soak ~24 h.
2. **All**: copy the var into `inventory/group_vars/all.yml` and drop it from `canary.yml`. Each store converges on its next 2 AM.
3. **Rollback**: `git revert` the offending commit. Same convergence window. No special tooling.

Note that a value pinned in `host_vars/<slug>.yml` outranks canary — so canarying a var that a host_vars file also pins will look like it did nothing on that host. Warehouse currently pins `activate_agent_ref` in both places; see `CLAUDE.md` § "Fleet default is pinned, Warehouse tracks main".

## What a Pi reports back

Every run writes state to disk, so a failed pull is visible rather than merely absent:

| File | Written | Contains |
|---|---|---|
| `/var/lib/activate-wled/last-ansible-pull.json` | start of every run | `started_at`, host, agent mode |
| `/var/lib/activate-wled/last-ansible-pull-ok.json` | only on full success | `finished_at`, **resolved** `cloudflared_version` and `activate_agent_ref` |
| `/var/log/activate-wled/ansible-pull.log` | every run | full stdout/stderr + an `OK` line per success |

The `-ok.json` file is the one that matters for drift: it records what the Pi *actually* converged to, which is the only way to tell "no changes needed" apart from "the pins never arrived."

## Sibling repos

| Repo | Role |
|---|---|
| [`Soundsfun-com/activate.leds.dashboard`](https://github.com/Soundsfun-com/activate.leds.dashboard) | Next.js dashboard (control plane), Pi image + flasher config, the Firmware console that writes this repo |
| `Soundsfun-com/activate.leds.agent` (private) | Python agent that runs on each Pi; cloned here at the pinned ref |
| **`Soundsfun-com/activate.leds.ansible`** (this) | Fleet-sync state convergence (config plane) |

## Local development

```bash
# Syntax check (needs: pip install ansible-core && ansible-galaxy collection install -r requirements.yml)
ansible-playbook --syntax-check playbooks/site.yml

# The tests CI runs
tests/test_site_identity.sh    # canary + per-site pins + precedence
tests/test_hostname.sh         # ACT-LED-Pi-<Store> resolves; rejects illegal chars
tests/test_pull_cadence.sh     # both cadence branches; baked-trigger clearing
tests/test_patch_window.sh     # security upgrade + reboot times agree
tests/test_docs_current.sh     # this README + CLAUDE.md still match the shipping config
                               # (needs no ansible; cross-checks the baked timer
                               #  too when ../dashboard is checked out beside this)

# Lint
ansible-lint playbooks/site.yml
```

There is no test inventory — the play targets `localhost` by design, so the tests above render templates and assert on the output instead of running a play.
