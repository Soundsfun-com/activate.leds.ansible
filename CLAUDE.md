# Activate fleet config — working notes

What version of what runs on each store's Raspberry Pi. A **claimed** Pi runs
`ansible-pull` against this repo at **02:00 local, once a day** (plus ~5 min
after boot). An **unclaimed** Pi — flashed but not yet assigned to a store —
runs it **every ~10 min**, because until a pull installs the agent it can't
appear on the dashboard's Assign tab at all (see Rule 4). Same-day pushes to
claimed stores go through the dashboard's "Update all agents" button.

This repo is small and boring on purpose, and it keeps producing
production-affecting bugs — every one of them by **doing nothing silently**: a
pin that never loaded, a schedule that looked ignored, a patch that downloaded
and stopped, a Pi that vanished until 2am, a page of hard-won explanation
deleted by a button click. Read the five rules below before changing anything.

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

## Rule 4 — an unclaimed Pi's cadence IS its time-to-appear

The Pi image bakes the agent's virtualenv but **not the agent code** — that
arrives with the first `ansible-pull`. Nothing announces a Pi to the dashboard's
Assign tab until that agent is running, so on a fresh Pi "how often do we
converge" and "how long before an installer can assign this box" are the same
number.

That's why `roles/base` branches the cadence on claimed-ness (reusing
site-identity's `site_slug | default('') | length > 0`, so there is exactly one
test of it in the repo):

| | cadence | why |
|---|---|---|
| unclaimed | `ansible_pull_unassigned_oncalendar` — every ~10 min | it's invisible until a pull lands |
| claimed | `ansible_pull_oncalendar` — 02:00 local | it's running the lights; converge while the store is empty |

Two things this also defuses, both of which were silent:

- **The ordering latch.** `base` runs *before* `activate-agent`, so the drop-in
  is written before the agent exists. When it unconditionally wrote the daily
  schedule, any failure at-or-after `base` retired the image's retry and left a
  Pi with no agent and no next attempt until 2am — and a Pi with no agent can't
  report anything. On the fast cadence it retries within ~10 min and heals.
- **The baked jitter.** The image's timer used to carry
  `RandomizedDelaySec=55min`, justified as "spread the 28-store fleet" — a
  rationale that never applied, since claimed Pis are governed by the drop-in,
  not that file. All it actually spread was unclaimed Pis, at random, across an
  hour. Now 90s + 60s jitter. **Keep the baked timer at least as fast as
  `ansible_pull_unassigned_oncalendar`** — it lives in the dashboard repo
  (`infra/pi-image/stage3-activate/03-ansible-pull/files/`) and only reaches a
  Pi on re-flash.

`tests/test_pull_cadence.sh` renders both branches and asserts them (plus the
Rule 2 clearing). Re-assignment caveat: unassigning a Pi makes the agent
self-unenroll, but the timer only flips back to fast on its *next* pull — which
is still the store cadence. To get such a Pi back on the Assign tab now:
`systemctl start activate-ansible-pull.service` (or reboot — `OnBootSec`
survives every drop-in).

## Rule 5 — every file the dashboard writes loses its comments

**`inventory/` is machine-managed. Comments you put in these three files WILL be
deleted, without warning, the next time anyone clicks a button:**

| file | rewritten by |
|---|---|
| `inventory/group_vars/all.yml` | Firmware console → promote to fleet |
| `inventory/group_vars/canary.yml` | Firmware console → canary a version |
| `inventory/host_vars/<slug>.yml` | Firmware console → pin / unpin a site |

The mechanism is `js-yaml` in the dashboard's
`packages/api/src/integrations/ansible-repo/client.ts`: `yaml.load()`, mutate the
object, `yaml.dump()`. js-yaml has no concept of comments, so they don't survive
the round-trip. Keys survive; prose does not.

This has already bitten. On 2026-08-12 `56b163c dashboard: canary agent → main`
(issued from /controllers Edge Devices) added ONE key to `canary.yml` and
silently erased all 25 lines of comments in it — the staged-rollout workflow and
the hostname rollout's rationale, both written hours earlier. Restored below and
under "Pi hostnames", in the one place a button click can't reach.

**So: explanation goes HERE, never in `inventory/`.** Recover erased prose with
`git show <commit-before>:inventory/group_vars/canary.yml`.

### The canary staged-rollout workflow

This is the process that lived in `canary.yml`'s header until it was erased.
`canary.yml` applies only to slugs listed in `canary_sites` (today:
`[warehouse]`), and precedence is
`all.yml < canary.yml < host_vars/<slug>.yml`.

1. Set a var in `canary.yml` (e.g. `activate_agent_ref: v1.5.0`).
2. Push. Canary Pis converge on their next pull.
3. Soak 24h; watch the dashboard for regressions.
4. Healthy → copy the var into `all.yml` and drop it from `canary.yml`. The whole
   fleet converges on its next pull.
5. Broken → revert. Canary returns to `all.yml`'s value on the next pull.

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

## Pi hostnames: ACT-LED-Pi-<Store>

A freshly-flashed Pi is `ACT-LED-Pi-Unclaimed` (baked by the image — set in TWO
places that must agree: `dashboard/infra/pi-image/config` → `TARGET_HOSTNAME`
and `.github/workflows/build-pi-image.yml` → `hostname:`). Once enrollment
writes a `site_slug`, the `base` role renames it to `ACT-LED-Pi-<Store>` — so a
Pi still called "Unclaimed" is one nobody has assigned yet, and every other Pi
is identifiable in its store's router client list and over mDNS
(`ACT-LED-Pi-Alpharetta.local`).

Controlled by `activate_hostname_pattern`. The role default is `""`, which
means **do nothing** — that's both the pre-rollout state and the revert path.
`resolve-hostname.yml` title-cases the slug (`american-dream` →
`American-Dream`) so the store reads the way people write it. An explicit
`desired_hostname` in `host_vars/<slug>.yml` still outranks the pattern.

**Hyphens only — this is a correctness rule, not a style one.** The name was
requested as `ACT-LED Pi-[Alpharetta]`; the space and brackets are invalid in a
hostname and `hostnamectl` refuses them. Underscores are legal but some routers
mangle them in the DHCP client list, which is the one screen this naming exists
to improve. Letters, digits and hyphens is the safe set, and
`tests/test_hostname.sh` fails the build on anything else.

**Staged on purpose.** The pattern currently lives in `canary.yml` with
`canary_sites: [warehouse]`, NOT in `all.yml`. Reason: `base` runs 2nd in
`site.yml`, so if `hostnamectl` rejects a name the play aborts before
`activate-agent` and `cloudflared` converge — the Pi keeps running but stops
updating, with no signal. Fleet-wide, unattended, at 2am. Before promoting the
line into `all.yml`, confirm on Warehouse:

    hostnamectl set-hostname ACT-LED-Pi-Warehouse && hostnamectl status

Nothing else in the fleet reads the system hostname: Pi registration keys on
the hardware serial, and Cloudflare tunnel/DNS names come from the location
slug in the DB. Renaming is safe; the only risk is the rename itself failing.

## Fleet default is pinned, Warehouse tracks main

Until 2026-07-28, `all.yml` pinned `activate_agent_ref: main` — meaning every
merge to the agent repo's main branch was already a fleet-wide deploy to all
28 stores within the hour, whether or not anyone meant to ship it yet.

`all.yml` now pins an explicit SHA (today's value is just main's HEAD at the
moment of the cutover — a freeze, not a deliberate version choice; nothing
changed for the other 27 stores. Future bumps here ARE deliberate promotions).
`host_vars/warehouse.yml` pins `activate_agent_ref: main`, which
outranks the fleet default per the precedence above. Net effect: pushing to the
agent repo's main now reaches Warehouse (the real-hardware test rig) within the
hour, and reaches everywhere else only when someone edits `all.yml`'s pin —
by hand, or via the dashboard's Firmware console "promote to fleet" action.

Testing an agent change: push to the agent repo's main, wait for Warehouse's
next `ansible-pull`, confirm on the Pi at
`/var/lib/activate-wled/agent-checkout.json` (or the dashboard's
`/api/trpc/locations.getAgentSystem?input={"json":{"slug":"warehouse"}}`).
Promoting to the fleet: bump the SHA in `all.yml`.

Warehouse's pin was set by committing `host_vars/warehouse.yml` directly, not
via the dashboard's `pinSite` — so there's no matching `location_version_pins`
row, and the Firmware console's Edge Devices matrix will show Warehouse's
`agent` component as unpinned even though the file pin is live. Re-pin once
from that UI (value `main`, ≤32 chars so a full SHA won't fit — branch/tag
names and short SHAs do) if you want the two to agree.

**Warehouse's agent ref is now pinned in two places.** `56b163c` (canary a
version, from the Firmware console) put `activate_agent_ref: main` into
`canary.yml`, and `host_vars/warehouse.yml` already pinned the same value. Both
say `main` today so nothing is broken — but `host_vars` **outranks** canary, so
editing the canary value alone will look like it did nothing on Warehouse. To
move Warehouse off `main`, change `host_vars/warehouse.yml`. To use canary as a
real canary again, drop `activate_agent_ref` from `host_vars/warehouse.yml` so
the canary value is the one that wins.

## Verifying

    tests/test_site_identity.sh          # needs: pip install ansible-core
    tests/test_hostname.sh
    tests/test_pull_cadence.sh
    tests/test_patch_window.sh
    ansible-playbook --syntax-check playbooks/site.yml

CI runs both plus the guards above.
