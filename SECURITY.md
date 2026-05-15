# Security policy

## What this repo does and doesn't contain

This repo holds the Ansible fleet-sync configuration for the Activate WLED Raspberry Pi fleet. It is **public** because it contains **no credentials, no network topology, and nothing that grants access to anything**. The hard security boundary for the fleet is enforced elsewhere (see below), not by the privacy of this repo.

### Explicitly NOT in this repo (and never should be)

- ❌ WiFi SSIDs or passwords
- ❌ Cloudflare API tokens, account IDs, or zone IDs
- ❌ Cloudflare Access service tokens
- ❌ Per-Pi agent bearer tokens
- ❌ The dashboard's `INTEGRATIONS_SECRET_KEY` or any other AES key
- ❌ Internal LAN IP addresses or network topology
- ❌ Roller, Neon, R2, Sentry, or Slack credentials
- ❌ Any private key, JWT, or shared secret

Any of the above would be a **security incident**. Push protection and secret scanning are enabled on this repo — GitHub will refuse a commit that matches a known credential pattern. If a credential ever lands here anyway: rotate it immediately, then `git filter-repo` the commit out, then file a postmortem.

### Where secrets actually live

| Secret | Location |
|---|---|
| WiFi SSID/password for each site | `/etc/activate-wled/agent.toml` on each Pi (root-only, mode 0600). Written at enrollment. |
| Cloudflare API token | Encrypted in the dashboard's `integrations` table (Neon Postgres), AES-256-GCM with `INTEGRATIONS_SECRET_KEY`. |
| Agent bearer tokens (per-site) | Hashed-only in dashboard DB; raw value lives only on the Pi at `/etc/activate-wled/agent.toml`. |
| `INTEGRATIONS_SECRET_KEY` | Vercel env var (production) + GitHub secret (CI). |
| Roller API key | Encrypted in dashboard DB (same pattern as Cloudflare). |

### What protects the fleet

Not the privacy of this repo. The real security boundary:

1. **Cloudflare Access** gates every agent endpoint. Reaching one requires a service token issued to the cloud worker fleet or a Google SSO session for an allowlisted email domain (`@soundsfun.com`, `@activate.games`, `@breakoutgames.com`).
2. **Outbound-only Cloudflare Tunnels.** No port forwards. Pis are unreachable from the public internet.
3. **Per-Pi bearer tokens** authenticate Pi → cloud telemetry POSTs.
4. **WiFi network isolation.** Pis and WLED controllers live on store WiFi behind NAT; no cross-store routing.
5. **WLEDs are LAN-only.** No WLED is reachable from the internet directly.

Making this repo public weakens none of the above.

## Reporting a vulnerability

If you find a vulnerability — in this repo or in the broader Activate WLED system — please email **security@soundsfun.com** rather than opening a public issue. We'll acknowledge within 2 business days.

For everyday bugs in this repo (not security-sensitive), open a normal GitHub issue.
