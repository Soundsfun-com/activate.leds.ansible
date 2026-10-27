# activate.leds.ansible

Fleet configuration for the Raspberry Pis that run Activate's in-store LED lighting.

Every store Pi runs `ansible-pull` against this repo on a schedule and converges itself to whatever the `main` branch declares: which version of the agent it runs, which `cloudflared` it runs, its hostname, OS hardening, and when it patches. This is the **config plane** of the fleet. The [dashboard](https://github.com/Soundsfun-com/activate.leds.dashboard) is the control plane — it talks to each Pi live through a Cloudflare Tunnel, and it also *writes* to this repo when someone pins or promotes a version.

> **Working notes live in [`CLAUDE.md`](./CLAUDE.md), not here.** That file carries the six rules that keep this repo from silently doing nothing, the hostname history, the canary workflow, and the current Warehouse pin. This README is orientation: what the repo is, how a Pi consumes it, how a change reaches the stores. When the two disagree, `CLAUDE.md` is authoritative.

## Why this repo is public

It contains **only configuration patterns and conventions** — no credentials, no internal IPs, nothing that grants access to anything. The fleet's security boundary lives elsewhere (Cloudflare Access, outbound-only tunnels, per-Pi bearer tokens). Being public means:

- Pis clone **this** repo over plain HTTPS with no auth — no shared deploy key to leak or rotate. (The private *agent* repo is a separate clone and does use a baked deploy key — see below.)
- "No secrets in git" is enforced by GitHub's push protection and is auditable in the open.
- Anyone in the org can review fleet-config changes without a repo invitation.

See [`SECURITY.md`](./SECURITY.md) for the full "what's not in this repo" list and where secrets actually live.

## What lives here

```
.
├── CLAUDE.md                      # the six rules + rollout history — read before changing anything
├── SECURITY.md                    # what must never be committed, and where secrets live instead
├── ansible.cfg                    # points Ansible at inventory/28-stores.yml
├── requirements.yml               # community.general + ansible.posix (installed by ansible-pull)
├── inventory/                     # ALL vars live under here — see Rule 1. MACHINE-MANAGED.
│   ├── 28-stores.yml              # ZERO hosts despite the name (see its header). The filename
│   │                              # is baked into every Pi's systemd unit; do NOT rename it.
│   ├── group_vars/
│   │   ├── all.yml                # fleet-wide values + the inventory_vars_loaded sentinel
│   │   └── canary.yml             # overrides for the slugs listed in `canary_sites`
│   └── host_vars/
│       └── <slug>.yml             # per-store overrides (hand-loaded by site-identity)
├── playbooks/
│   └── site.yml                   # the ansible-pull target
├── roles/                         # run in this order — the order is load-bearing
│   ├── site-identity/             # 1. which store am I? layers canary + per-store vars
│   ├── base/                      # 2. hostname, timezone, log dirs, logrotate, pull cadence, MOTD
│   ├── udev-rules/                # 3. USB-serial permissions for flashing WLED boards
│   ├── security/                  # 4. sshd hardening, fail2ban, security patches in a window
│   ├── activate-agent/            # 5. clones the agent at the pinned ref; venv, systemd, tunnel apply
│   └── cloudflared/               # 6. pins the Cloudflare Tunnel client version
└── tests/                         # render-and-assert scripts; CI runs all six
```

Each role has its own README with the task-by-task detail.

## What one run does

`playbooks/site.yml` targets `localhost` — every Pi converges itself. In order:

1. **Prove the vars loaded.** `pre_tasks` asserts the `inventory_vars_loaded` sentinel from `inventory/group_vars/all.yml`. If vars ever stop loading, the run fails on the first Pi instead of quietly falling back to stale defaults (Rule 1). Then it records the start of the run to disk.
2. **`site-identity`** reads `site_slug` from `/etc/activate-wled/agent.toml` (written when the Pi is assigned to a store on the dashboard). No slug = unclaimed. With a slug, it layers `canary.yml` (if the slug is in `canary_sites`) and then `host_vars/<slug>.yml` on top of the fleet defaults.
3. **`base`**
   - **Hostname**: `ACT-LED-Pi` when claimed, `ACT-LED-Pi-Unclaimed` when not. Every store uses the same name because the store's Activate game server sends the lights Pi webhooks (e.g. fire alarm → all lights white) at one fixed address. Pis are told apart on the dashboard by hardware serial, MAC, IP and the Identify blink — never by hostname.
   - **Router re-announce**: a store router only learns a name from a DHCP request, so after a rename `base` reconnects the network once (~60 s after the pull, recording the name first so it can never loop; reboots only if the network doesn't come back within 90 s). Kill switch: `activate_dhcp_reannounce: false`.
   - Timezone (`site_timezone`, default `America/New_York`), log/state directories, logrotate, MOTD.
   - **Pull cadence** — see the next section.
4. **`udev-rules`** — lets the agent talk to USB-serial chips (for recovery-flashing a WLED board) without root. Same rules the image bakes; this repairs drift.
5. **`security`** — keys-only SSH as `activate-wled`, fail2ban, and unattended security upgrades that install *and* reboot inside the maintenance window (`maintenance_window_start_hour` → `maintenance_window_end_hour` in `all.yml`). `apt_upgrade_blacklist` holds packages back from auto-upgrade.
6. **`activate-agent`** — clones the private agent repo at `activate_agent_ref`, refreshes Python deps when `requirements.txt` changes, installs the agent's systemd unit, a narrow sudoers whitelist for the agent's self-update endpoints, and `activate-apply-tunnel` (which turns the tunnel token written at assignment into a running `cloudflared` service). Records what it checked out in `/var/lib/activate-wled/agent-checkout.json`.
7. **`cloudflared`** — makes the installed tunnel client match `cloudflared_version`, downloading the pinned release with retries when it drifts.
8. **Record success** — only if every role succeeded (see "What a Pi reports back").

## How a Pi pulls this

The Pi image (built from the dashboard repo's `infra/pi-image/`) ships:

- A oneshot service `activate-ansible-pull.service` that runs:
  ```
  ansible-pull \
    --url https://github.com/Soundsfun-com/activate.leds.ansible.git \
    --directory /var/lib/activate-ansible \
    --inventory inventory/28-stores.yml \
    --purge \
    playbooks/site.yml
  ```
  No `--checkout`, so every Pi tracks **`main`**. That command is baked into the image.
- A systemd timer `activate-ansible-pull.timer` with a deliberately impatient baked schedule (`OnBootSec=90s`, `OnUnitActiveSec=10min`, `RandomizedDelaySec=60s`). **That baked schedule governs exactly one situation: a Pi that has never completed a pull.** From the first successful pull onward, the `base` role's drop-in owns the cadence.
- The agent's Python virtualenv (but **not** the agent code — the first pull installs that).
- A read-only deploy key at `/etc/ansible/agent-deploy-key` for the **private agent repo**, which `activate-agent` clones over SSH. This repo itself needs no key.

### Cadence: it depends on whether the Pi is claimed

| Pi state | Converges | Why |
|---|---|---|
| **Unclaimed** (flashed, not yet assigned to a store) | every ~10 min | Until a pull installs the agent, the Pi can't appear on the dashboard's Assign tab — so cadence *is* how long an installer waits. |
| **Claimed** (has a `site_slug`) | **02:00 in the store's own local time**, +0–30 min jitter — and only then | It's running the lights. Converge while the building is empty. |

The real values live in `ansible_pull_oncalendar` (`inventory/group_vars/all.yml`) and `ansible_pull_unassigned_oncalendar` (`roles/base/defaults/main.yml`); `tests/test_docs_current.sh` fails CI if this README stops matching them.

`site_timezone` decides when 2 AM is; it defaults to `America/New_York`, so a store outside Eastern needs it set in its `host_vars/<slug>.yml`.

**So: a change pushed to `main` reaches a claimed store on its next 2 AM — up to ~24 h.** Same for a `git revert`. When that's too slow, use the dashboard's **Edge Pis** page (`/pis`): **Update all agents** triggers a pull on every store now, and each store's row has its own **Update agent**. To converge one Pi by hand over SSH: `sudo systemctl start activate-ansible-pull.service` (~2 min). **Rebooting a claimed Pi does not trigger a pull** — verified on Fishers 2026-09-08: after a mid-afternoon reboot its next pull was still 02:28 the next morning. Don't "temporarily" speed up the fleet cadence instead — that widens the window in which a bad commit reaches every store.

## This repo has no dev/prod split

The dashboard has two environments (production from its `main` branch, dev from its `dev` branch). **This repo does not**: because the pull command above is baked into the image with no branch, every Pi — whichever dashboard it reports to — converges against this repo's `main`. A change landed here "just for the dev Pi" reaches the stores at 02:00 that night.

To try something on one Pi, use the tools that *are* scoped:

- **`canary.yml`** — reaches only the slugs in `canary_sites`.
- **`host_vars/<slug>.yml` → `activate_agent_ref: dev`** — runs the agent repo's `dev` branch on one store only.

Details: `CLAUDE.md` § "This repo is NOT split by environment", and the dashboard repo's `docs/environments.md`.

## Who writes this repo

People push here directly, but so does the dashboard. Its buttons commit through the GitHub API:

| Dashboard action | Writes |
|---|---|
| Edge Pis → Tools → fleet software pins → save (agent ref, `cloudflared` version) | `inventory/group_vars/all.yml` |
| Edge Pis → Tools → fleet software pins → canary a version on chosen stores | the version → `inventory/group_vars/canary.yml`; the chosen stores → `canary_sites` in `all.yml` |
| Edge Pis → Locations → a store's row → pin / unpin a version | `inventory/host_vars/<slug>.yml` |

(The commit messages these buttons write still say "via /firmware Edge Devices" — an old screen name. The buttons are on the Edge Pis page.)

> **Everything under `inventory/` is MACHINE-MANAGED — don't put comments there.**
> The dashboard round-trips these files through `js-yaml` (`load` → mutate → `dump`),
> which has no concept of comments. Keys survive; prose is deleted without warning
> on the next button click. This has already happened (2026-08-12: a one-key canary
> write erased 25 lines of rollout rationale). Durable explanation goes in
> `CLAUDE.md`, in role comments, or in a CI guard. Recover erased prose with
> `git show <commit-before>:<path>`.

> **group_vars/host_vars MUST stay under `inventory/`.** Ansible resolves them relative to the inventory file or the playbook — never the repo root. They lived at the repo root until 2026-07-26, so nothing loaded them: roles fell back to their own defaults, every task was skipped, and each run reported success while the fleet stayed on the version baked into the image. The `inventory_vars_loaded` sentinel and a CI check now make a repeat fail loudly. For the same reason, **version pins have no role default** — an unloaded pin must fail the run, not reuse a stale value.

## What's running right now

Read [`inventory/group_vars/all.yml`](./inventory/group_vars/all.yml) — don't trust a version quoted in any doc, including this one; the dashboard rewrites that file. The keys that matter:

| Key | Controls |
|---|---|
| `activate_agent_ref` | agent branch / tag / SHA for every un-pinned store. When it's `main`, **merging to the agent repo's `main` is a fleet-wide deploy** at the next 02:00. |
| `cloudflared_version` | Cloudflare Tunnel client release |
| `canary_sites` | which slugs take `canary.yml` |
| `activate_hostname_pattern` | the claimed-Pi hostname (empty = rename nothing; that's the revert path) |
| `auto_apply_security_patches`, `maintenance_window_*_hour` | whether and when security patches install and reboot |
| `ansible_pull_oncalendar` | the claimed-store convergence time |

For what a given store *actually* converged to, ask the Pi (below) or the dashboard's `locations.getAgentSystem` endpoint — not this repo.

## Staged rollouts

Precedence is `all.yml` < `canary.yml` (only if the Pi's slug is in `canary_sites`) < `host_vars/<slug>.yml`. The canary is resolved by `site-identity` reading the slug, *not* by Ansible inventory groups (every Pi runs as `localhost`, which belongs to no group).

1. **Canary**: put the var in `inventory/group_vars/canary.yml`. Soak ~24 h; watch the dashboard.
2. **All**: copy the var into `inventory/group_vars/all.yml` and drop it from `canary.yml`. Each store converges on its next 2 AM.
3. **Rollback**: `git revert` the offending commit. Same convergence window. No special tooling.

A value pinned in `host_vars/<slug>.yml` outranks canary — so canarying a var that a host_vars file also pins looks like it did nothing on that host. See `CLAUDE.md` § "What the fleet runs" for the current Warehouse double-pin.

## What a Pi reports back

Every run writes state to disk, so a failed pull is visible rather than merely absent:

| File | Written | Contains |
|---|---|---|
| `/var/lib/activate-wled/last-ansible-pull.json` | start of every run | `started_at`, host, agent mode |
| `/var/lib/activate-wled/last-ansible-pull-ok.json` | only on full success | `finished_at`, **resolved** `cloudflared_version` and `activate_agent_ref` |
| `/var/lib/activate-wled/agent-checkout.json` | when `activate-agent` runs | the agent ref actually checked out |
| `/var/log/activate-wled/ansible-pull.log` | every run | full output + an `OK` line per success |

The `-ok.json` file is the one that matters for drift: it records what the Pi *actually* converged to — the only way to tell "no changes needed" apart from "the pins never arrived."

These files stay on the Pi. From the dashboard you can see the same story two ways: the Edge Pis page shows the versions each store's agent reports live in its heartbeat, and `/sites/<slug>/agent-logs?unit=ansible-pull` reads the pull's journal through the store's tunnel — the first place to look when a store stops converging.

## Sibling repos

| Repo | Role |
|---|---|
| [`Soundsfun-com/activate.leds.dashboard`](https://github.com/Soundsfun-com/activate.leds.dashboard) | Cloud dashboard (control plane), Pi image + flasher builds, and the buttons that write this repo |
| `Soundsfun-com/activate.leds.agent` (private) | Python agent that runs on each Pi; cloned here at the pinned ref |
| **`Soundsfun-com/activate.leds.ansible`** (this) | Fleet config convergence (config plane) |

## Local development

```bash
# Setup
pip install ansible-core
ansible-galaxy collection install -r requirements.yml

# Syntax check
ansible-playbook --syntax-check playbooks/site.yml

# The tests CI runs (.github/workflows/test.yml, on every push to main and every PR)
tests/test_site_identity.sh     # canary + per-site pins + precedence
tests/test_hostname.sh          # claimed → ACT-LED-Pi, unclaimed → ACT-LED-Pi-Unclaimed; rejects illegal chars
tests/test_dhcp_reannounce.sh   # router re-announce fires once per new name — never zero times, never nightly
tests/test_pull_cadence.sh      # both cadence branches; baked-trigger clearing
tests/test_patch_window.sh      # security upgrade + reboot times agree
tests/test_docs_current.sh      # this README + CLAUDE.md still match the shipping config
                                # (needs no ansible; cross-checks the baked timer
                                #  too when ../dashboard is checked out beside this)

# Lint
ansible-lint playbooks/site.yml
```

There is no test inventory — the play targets `localhost` by design, so the tests render the real templates and assert on the output instead of running a play. CI also fails if `group_vars/` or `host_vars/` reappear at the repo root, or if the `inventory_vars_loaded` sentinel disappears.
