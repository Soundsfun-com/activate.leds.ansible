# role: cloudflared

Pins the `cloudflared` (Cloudflare Tunnel client) version on every Pi: a
bumped `cloudflared_version` in `group_vars/all.yml` (set from the
dashboard's Edge Devices → software pins panel) propagates to the fleet on
the next ansible-pull.

Does **not** manage tunnel config — that's enrollment-time territory
(`activate-apply-tunnel` installs the service from the claim token).

## How it works

1. `/usr/local/bin/cloudflared --version` — no-op when the pinned version
   is already installed.
2. On drift (or missing binary): download the pinned release's standalone
   `cloudflared-linux-arm64` binary straight over `/usr/local/bin/cloudflared`
   (atomic rename, safe while running).
3. Handler `systemctl try-restart cloudflared.service` — restarts the tunnel
   only if it's running; unclaimed Pis just get the fresh binary.

**Why the standalone binary and not the .deb:** the pi-gen image bakes the
binary at `/usr/local/bin/cloudflared`, and both the tunnel's systemd unit
(written by `cloudflared service install`) and the agent's sudoers-
whitelisted `cloudflared update` path reference that absolute path. The
.deb installs to `/usr/bin`, which would leave the service running the old
copy forever.

## Vars

| Var | Default | Notes |
|---|---|---|
| `cloudflared_version` | from `group_vars/all.yml` | Release tag, e.g. `2026.7.2` |
