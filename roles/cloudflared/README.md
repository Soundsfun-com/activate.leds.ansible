# role: cloudflared

Pins the `cloudflared` (Cloudflare Tunnel client) version on every Pi: a
bumped `cloudflared_version` in `group_vars/all.yml` (set from the
dashboard's Edge Devices → software pins panel) propagates to the fleet on
the next ansible-pull.

Does **not** manage tunnel config — that's enrollment-time territory
(`activate-apply-tunnel` installs the service from the claim token).

## How it works

1. Resolve the REAL binary: `/usr/local/bin/cloudflared` is a symlink created
   by the .deb's postinst, so follow it (normally to `/usr/bin/cloudflared`).
2. `<binary> --version` — no-op when the pin is already installed.
3. On drift (or a missing binary): download the pinned release's standalone
   `cloudflared-linux-arm64` straight over that path (atomic rename, safe
   while the tunnel is running), with 3 retries — this is the last role in
   `site.yml`, and one flaky reach out to github.com from a store's network
   otherwise aborts the entire pull.
4. Re-assert the `/usr/local/bin/cloudflared` symlink, so every caller
   (`command -v`, the agent's version probe, the sudoers entry, a future
   `cloudflared service install`) resolves to the SAME file.
5. Handler `systemctl try-restart cloudflared.service` — restarts the tunnel
   only if it's running; unclaimed Pis just get the fresh binary.

**Layout, verified against the actual .deb (2026-07-25).** An earlier version
of this README claimed the image bakes a standalone binary at
`/usr/local/bin/cloudflared` and that the .deb "installs to /usr/bin, which
would leave the service running the old copy forever." That was wrong in a way
that mattered. Cloudflare's .deb ships exactly one binary at
`/usr/bin/cloudflared` and its **postinst symlinks**
`/usr/local/bin/cloudflared → /usr/bin/cloudflared`. The image `dpkg -i`s that
.deb, so both paths are the same file. Managing the symlink path instead of the
real one risks leaving two divergent binaries on disk, which makes "what
version is actually running?" depend on which path a caller resolved — and the
dashboard would happily report the newer of the two while the tunnel ran the
older.

## Vars

| Var | Default | Notes |
|---|---|---|
| `cloudflared_version` | from `group_vars/all.yml` | Release tag, e.g. `2026.7.2` |
