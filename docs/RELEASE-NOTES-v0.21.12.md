# CPZ-Alpine v0.21.12 — reinstall only the missing packages

## What's new

- `cpz-wifi.start` now computes the **missing** package set (from
  `/cfg/world`) and runs `apk add` on exactly those names. v0.21.10/11 fed
  `apk add` the entire world in one transaction; on the device that
  transaction failed (while a plain `apk add tailscale` succeeds), so the
  retry loop ran for three minutes and Tailscale stayed missing after a
  reflash — the field report: `sudo tailscale up` → `command not found`.
- Local `.apk` files (`/cfg/apk/*.apk`) and the custom
  repositories/keys handling are unchanged.
- The v0.21.11 structural fixes are unchanged: `cpz-restore` runs in the
  boot runlevel before `applaunch`/`dropbear`/`networkmanager`, and the
  flasher verifies the snapshot rewrite byte-for-byte before finishing.

## Untested / needs a hardware pass

- The missing-only install was not yet exercised on hardware; the previous
  whole-world failure was diagnosed from the device (manual
  `apk add tailscale tailscale-openrc` succeeds, boot hook install failed).
- Check after the next flash: `sudo cat /run/cpz-pkg.status` → `ok`,
  `/var/log/cpz-pkg.log` shows the successful `apk add`, and
  `pidof tailscaled` is non-empty after Wi-Fi connects.
