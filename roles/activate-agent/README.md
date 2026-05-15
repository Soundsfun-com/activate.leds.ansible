# role: activate-agent (NOT YET IMPLEMENTED)

Will clone the Python edge agent into `/opt/activate-wled-agent/agent/` at the pinned ref, write the systemd unit, and restart on change.

## Blocker

The agent code currently lives in the **private** `Soundsfun-com/activate.leds.dashboard` repo at `agent/`. Ansible can't clone a private repo without credentials, which we deliberately don't put on Pis (see this repo's `SECURITY.md`).

## Resolution (decided, not yet executed)

Split the agent code into a **public** sibling repo: **`Soundsfun-com/activate.leds.agent`**. Same rationale as this repo — agent source has no embedded secrets (secrets load from `/etc/activate-wled/agent.toml` at runtime). Dashboard stays private.

Once that repo exists, this role will:

```yaml
- name: Ensure agent checkout dir exists
  ansible.builtin.file:
    path: /opt/activate-wled-agent/agent
    state: directory
    owner: activate-wled
    mode: "0755"

- name: Clone or update agent code at the pinned ref
  ansible.builtin.git:
    repo: https://github.com/Soundsfun-com/activate.leds.agent.git
    dest: /opt/activate-wled-agent/agent
    version: "{{ activate_agent_ref }}"   # from group_vars/all.yml
    force: yes
  notify: restart-activate-wled-agent

- name: Install/update Python deps if requirements.txt changed
  ansible.builtin.pip:
    requirements: /opt/activate-wled-agent/agent/requirements.txt
    virtualenv: /opt/activate-wled-agent/venv
  notify: restart-activate-wled-agent

- name: Install activate-wled-agent.service systemd unit
  ansible.builtin.template:
    src: activate-wled-agent.service.j2
    dest: /etc/systemd/system/activate-wled-agent.service
  notify:
    - daemon-reload
    - restart-activate-wled-agent

- name: Ensure agent service is running
  ansible.builtin.systemd:
    name: activate-wled-agent
    enabled: yes
    state: started
```

## Configurable vars (when implemented)

| Var | Default | Notes |
|---|---|---|
| `activate_agent_ref` | `main` (from `group_vars/all.yml`) | Tag, branch, or sha to deploy. Bulk updates from `/firmware` Edge Devices tab edit this. |
| `activate_agent_mode` | derived from `agent_mode` (inventory group var) | `site` or `portable` — toggles the agent's runtime behavior |
