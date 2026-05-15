# role: activate-agent

Clones the Python edge agent into `/opt/activate-wled-agent/agent/` at the ref pinned in `group_vars/all.yml`, installs Python deps into the pre-baked venv, writes the systemd unit, restarts on change.

Source: **private** [`Soundsfun-com/activate.leds.agent`](https://github.com/Soundsfun-com/activate.leds.agent) repo, cloned via SSH using a read-only deploy key baked into the pi-gen image at `/etc/ansible/agent-deploy-key`.

## What it does

| Task | Why |
|---|---|
| Verify `/etc/ansible/agent-deploy-key` exists, mode 0600 | Fail fast if the Pi image didn't bake it in correctly |
| `git clone` (or pull) `activate.leds.agent` at `activate_agent_ref` into `/opt/activate-wled-agent/agent/` (as the `activate-wled` user) | Get the agent code at the pinned version |
| Re-install Python deps from `requirements.txt` if the checkout changed | Keep the venv in sync with whatever ref we just pulled |
| Copy `systemd/activate-wled-agent.service` from the checkout to `/etc/systemd/system/` | Pick up any unit-file changes that shipped with the new agent version |
| `systemctl enable + start activate-wled-agent` | Make sure the agent is running |
| Write `/var/lib/activate-wled/agent-checkout.json` (ref + timestamp) | The next telemetry POST can ship this so the dashboard knows what version is live |

## Configurable vars

| Var | Default | Notes |
|---|---|---|
| `activate_agent_repo` | `git@github.com:Soundsfun-com/activate.leds.agent.git` | SSH URL — deploy key required |
| `activate_agent_ref` | `main` (set in `group_vars/all.yml`) | Tag, branch, or sha. Bulk-update flow edits this. |
| `activate_agent_dir` | `/opt/activate-wled-agent` | Parent directory |
| `activate_agent_checkout` | `{{ activate_agent_dir }}/agent` | Where the git checkout lives |
| `activate_agent_venv` | `{{ activate_agent_dir }}/venv` | Pre-built by stage 02 of the pi-gen image |
| `activate_agent_ssh_key` | `/etc/ansible/agent-deploy-key` | Read-only deploy key baked into image |
| `activate_agent_service_enabled` | `true` | Set `false` on hosts that should clone code but not auto-start the service (e.g. portable flashers in recovery-only mode) |

## Auth flow

1. **Keypair generated once** (2026-05-15) — ed25519, read-only.
2. **Public half** registered as a read-only deploy key on `Soundsfun-com/activate.leds.agent`.
3. **Private half** stored as `AGENT_DEPLOY_KEY` repo secret on `Soundsfun-com/activate.leds.dashboard`.
4. **Pi image CI** (`build-pi-image.yml`) injects the private half into the rootfs at `/etc/ansible/agent-deploy-key` (mode 0600, owned by root) at image build time.
5. **Ansible role** uses that key (`GIT_SSH_COMMAND` env + `key_file:` arg) to clone.

To **rotate**:
```bash
WORK=$(mktemp -d) && cd "$WORK"
ssh-keygen -t ed25519 -f key -C "agent deploy key rotation $(date -u +%F)" -N ""
# Add new public key (don't delete the old one yet — it's still in use on flashed Pis)
gh api -X POST /repos/Soundsfun-com/activate.leds.agent/keys \
  -f title="pi-fleet-agent-pull-$(date -u +%Y%m)" -f key="$(cat key.pub)" -F read_only=true
gh secret set AGENT_DEPLOY_KEY --repo Soundsfun-com/activate.leds.dashboard --body "$(cat key)"
# Trigger a new Pi image build. Re-flash Pis from new image. Then delete old deploy key.
```

## Drift behavior

Because the role re-runs hourly via `ansible-pull`:
- If a field tech edits `/opt/activate-wled-agent/agent/` manually, the next pull `git reset --hard`s it back (`force: yes`).
- If the systemd unit file diverges (someone runs `systemctl edit`), the next pull rewrites it from the checked-out copy. Drop-ins under `/etc/systemd/system/activate-wled-agent.service.d/` are NOT managed by this role and survive.
- If the venv falls out of sync (pip install something by hand), the venv is unaffected until the agent repo's `requirements.txt` changes — at which point pip re-installs from a clean state.
