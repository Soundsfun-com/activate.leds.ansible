# role: base

OS-level baseline that every Pi in the fleet (site agent or portable flasher) converges to on every `ansible-pull`.

## What it does

| Task | Why |
|---|---|
| Set hostname to `ACT-LED-Pi-<Store>` (from the store slug; `activate_hostname_pattern` in `inventory/group_vars/all.yml`) | So each Pi is identifiable in its store's router client list and over mDNS (`ACT-LED-Pi-Alpharetta.local`) |
| Sync `/etc/hosts` with the hostname | Standard Debian convention, prevents sudo timeouts |
| Set system timezone (default `America/New_York`) | Cron + logs + manager-issued playlist overrides all rely on local time |
| Create `/var/log/activate-wled/` and `/var/lib/activate-wled/` | Standard paths the agent expects |
| Install logrotate policy for `/var/log/activate-wled/*.log` | Prevents disk fill |
| Render MOTD with site + agent + last-pull info | Useful for SSH'd-in field techs |

## Configurable vars

See `defaults/main.yml`. Override in `group_vars/all.yml` or `host_vars/<slug>.yml`.

| Var | Default | Notes |
|---|---|---|
| `site_timezone` | `America/New_York` | Per-site override possible |
| `activate_log_rotate_days` | `14` | Keep 2 weeks of logs |
| `activate_log_max_size_mb` | `50` | Rotate at 50 MB even if < 14 days |
