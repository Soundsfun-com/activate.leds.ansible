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

**Gated by `auto_apply_security_patches`.** The role default is `false` (a safe fallback for a host that somehow loads no vars): patches download but are NOT applied. The fleet sets it to `true` in `inventory/group_vars/all.yml` (since 2026-07-27). When true, two clocks move into the maintenance window (`maintenance_window_start_hour` → `maintenance_window_end_hour`): a drop-in pins `apt-daily-upgrade.timer` to the window start, and `Automatic-Reboot-Time` is the window END so a kernel patch reboots the same night. `tests/test_patch_window.sh` asserts both — see `CLAUDE.md` Rule 3.

`apt_upgrade_blacklist` (default empty) lists package-name regexes that are never auto-upgraded. Anything listed stops getting security fixes, so give each entry a reason and a review date.

### 3. fail2ban (SSH brute-force protection)
Installs + enables `fail2ban` with conservative defaults for the `sshd` jail:
- 5 failed auths within 10 min triggers a 1-hour ban
- Pis are LAN-only so this is belt-and-suspenders, but cheap insurance

Toggleable via `fail2ban_enabled` (default `true`).

## Configurable vars

See `defaults/main.yml`.

| Var | Default | Notes |
|---|---|---|
| `auto_apply_security_patches` | `false` | Fleet sets `true` in `inventory/group_vars/all.yml` |
| `apt_upgrade_blacklist` | `[]` | Package regexes held back from auto-upgrade |
| `fail2ban_enabled` | `true` | Set to `false` to uninstall |
| `ssh_allowed_users` | `[activate-wled]` | List of users permitted to SSH in |

## What it does NOT do

- Does not manage user accounts (the pi-gen image creates `activate-wled`; this role just configures sshd around it)
- Does not manage SSH host keys (those rotate on first boot via `activate-firstboot.sh`)
- Does not install or rotate authorized_keys for `activate-wled` — that's a separate concern handled at flash time by Pi Imager (and re-applied by a future `field-techs` role when we wire that up)
