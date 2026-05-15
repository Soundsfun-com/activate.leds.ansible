# role: udev-rules

Converges the USB serial access rules used for ESP32 flashing.

## What it does

| Task | Why |
|---|---|
| Install `/etc/udev/rules.d/99-activate-wled.rules` | Grants the `dialout` group `0660` access to `/dev/ttyUSB*` and `/dev/ttyACM*` for the common WLED-controller USB chips (CP210x, CH340, FTDI, Espressif native USB) |
| Ensure `activate-wled` user is in the `dialout` group | So the agent (`esptool` for recovery flashes) can talk to USB serial without root |
| `udevadm control --reload-rules && udevadm trigger` on change | Apply rule changes immediately without rebooting |

## Same rules baked into the image

These rules are also installed at image build time (`infra/pi-image/stage3-activate/04-udev-rules/`). This role exists to **repair drift** if anyone manually edits the rules on a Pi — the next `ansible-pull` puts them back.

## Why it's safe to keep both sources

Ansible is idempotent: if the file on disk matches the file in the role, nothing happens (no "changed" event, no handler triggered). Running this role on a freshly-imaged Pi is a no-op.

## Updating the rule list

When we add a new WLED hardware variant with a different USB serial chip:
1. Edit `files/99-activate-wled.rules` in this repo. Commit, push.
2. Edit `infra/pi-image/stage3-activate/04-udev-rules/files/99-activate-wled.rules` in the dashboard repo too. Commit, push.
3. Existing Pis pick up the change within ~1h via `ansible-pull`. Future-flashed Pis get it from the image.
