# role: cloudflared (NOT YET IMPLEMENTED)

Will pin the `cloudflared` (Cloudflare Tunnel client) version on every Pi, so a bumped `cloudflared_version` in `group_vars/all.yml` propagates to the fleet within ~1h.

Does **not** manage tunnel config — that's enrollment-time territory (the dashboard writes `/etc/cloudflared/config.yml` per Pi).

## What it will do (when implemented)

```yaml
- name: Check installed cloudflared version
  ansible.builtin.command: cloudflared --version
  register: cf_version_output
  changed_when: false
  failed_when: false

- name: Download pinned cloudflared .deb if version drifts
  ansible.builtin.get_url:
    url: "https://github.com/cloudflare/cloudflared/releases/download/{{ cloudflared_version }}/cloudflared-linux-arm64.deb"
    dest: "/tmp/cloudflared-{{ cloudflared_version }}.deb"
    checksum: "{{ cloudflared_sha256 | default(omit) }}"
  when: cloudflared_version not in cf_version_output.stdout

- name: Install the pinned version
  ansible.builtin.apt:
    deb: "/tmp/cloudflared-{{ cloudflared_version }}.deb"
  when: cloudflared_version not in cf_version_output.stdout
  notify: restart-cloudflared
```

## Why not now

Until we have agents enrolled and tunnels active, version pinning has nothing to converge against. Roll this in once the first Pi is running a real tunnel.

## Configurable vars (when implemented)

| Var | Default | Notes |
|---|---|---|
| `cloudflared_version` | `2024.12.2` (from `group_vars/all.yml`) | Matches the version baked into the pi-gen image |
| `cloudflared_sha256` | (unset) | Optional sha256 verification of the downloaded .deb |
