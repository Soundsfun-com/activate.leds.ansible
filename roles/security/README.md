# role: security

Security baseline applied to every Pi in the fleet. Idempotent re-runs repair drift.

## What it does

### 1. sshd hardening
Installs two drop-ins under `/etc/ssh/sshd_config.d/`:
- `00-activate-wled.conf` — keys-only auth, no passwords, no root, 3 max auth tries, 30s grace period, client keepalive 5min
- `01-activate-allowusers.conf` — `AllowUsers` driven by the `ssh_allowed_users` var (default `[activate-wled]`)

Triggers `sshd` restart on change.

### 2. unattended-upgrades (security patches)
Installs `unattended-upgrades` package + renders two policies:
- `/etc/apt/apt.conf.d/50unattended-upgrades` — restricts to `*-security` origins, autoreboot only inside the maintenance window
- `/etc/apt/apt.conf.d/20auto-upgrades` — apt-periodic settings (daily check, auto-download)

**Gated by `auto_apply_security_patches` (default `false`).** When false: patches are downloaded but NOT applied. Flip to `true` in `group_vars/all.yml` (or in `group_vars/canary.yml` first for a staged rollout) when ready to enable auto-patching.

### 3. fail2ban (SSH brute-force protection)
Installs + enables `fail2ban` with conservative defaults for the `sshd` jail:
- 5 failed auths within 10 min triggers a 1-hour ban
- Pis are LAN-only so this is belt-and-suspenders, but cheap insurance

Toggleable via `fail2ban_enabled` (default `true`).

## Configurable vars

See `defaults/main.yml`.

| Var | Default | Notes |
|---|---|---|
| `auto_apply_security_patches` | `false` | Set to `true` after validating on canary group |
| `fail2ban_enabled` | `true` | Set to `false` to uninstall |
| `ssh_allowed_users` | `[activate-wled]` | List of users permitted to SSH in |

## What it does NOT do

- Does not manage user accounts (the pi-gen image creates `activate-wled`; this role just configures sshd around it)
- Does not manage SSH host keys (those rotate on first boot via `activate-firstboot.sh`)
- Does not install or rotate authorized_keys for `activate-wled` — that's a separate concern handled at flash time by Pi Imager (and re-applied by a future `field-techs` role when we wire that up)
