# CPZ-Alpine v0.22.0 — stable persistence line

This is the consolidated, stable release of everything built and field-verified
through the 0.21 series. Older 0.21.x releases are removed: several of them
could lose settings, packages or the Wi-Fi/Tailscale state on a reflash, and
this release fixes every one of those paths.

## What's new in the 0.21.x → 0.22.0 line

**Persistence across a reflash**

- `cpz-restore` runs in the **boot runlevel, before** `applaunch`,
  `dropbear` and `networkmanager` — so the launcher loads the saved
  brightness/dark-time/volume, dropbear serves the saved host keys, and NM
  sees the saved Wi-Fi profiles at first scan. (The old `local.d` restore
  ran after all of them had already loaded defaults.)
- `flash-cpz.sh` protects `/cfg`: it repairs a dirty ext4 instead of
  formatting it, backs up `save.tar.gz`, `.prev`, `shadow-users`,
  `pkglist.txt`, `world`, `repositories`, `ntp`, `timezone`, `apk/` and
  `apk-keys/` into `cpz-cfg-backup-<time>/`, then **writes that snapshot
  back after the flash and verifies the byte count** — aborting loudly on
  any mismatch instead of silently booting an older archive.
- `cpz-save` snapshots every 5 minutes, on NetworkManager connect, on
  settings changes (inotify watcher), at shutdown (waiting for in-flight
  saves), and keeps the previous generation as `save.tar.gz.prev`.

**Settings that actually work**

- Brightness: the backlight sysfs node is made writable for the launcher.
- Speaker: the saved volume is re-applied after the boot mixer restore.
- Date & Time: network-time toggle (busybox `ntpd`, preference in
  `/cfg/ntp`) and manual time (`date -s` + `hwclock -w`) run directly with
  `sudo -n`, bypassing the systemd/sudo-prompt paths that never completed
  on Alpine.
- Timezone: `sudo cpz-timezone set <Region>/<City>` (plus `status`/`list`);
  the choice survives a reflash.

**Packages**

- Explicit packages (`/cfg/world`), custom repositories and signing keys,
  and local `.apk` files (`sudo cpz-apk add`) are reinstalled automatically
  after Wi-Fi connects; only the missing packages are installed, with a
  launcher toast ("Installing packages…" / "Packages ready").

**Apps**

- Tailscale on/off card (hidden until installed and logged in), HDMI
  desktop toggle, Files/Camera/Calculator — unchanged from the 0.21 line.

## Known issues

- A card pulled while a `cpz-save` write is in flight can still lose that
  save (up to the previous generation in `save.tar.gz.prev`).
- `/home/cpz` media rides the 5-minute + shutdown snapshot, not the
  inotify watcher.
- Packages that add their own OpenRC service need a start hook (Tailscale
  has one; arbitrary third-party services may need `rc-update add` after
  the reinstall).

## Flash

Download the ZIP, verify the SHA-256, then:

```sh
sudo ./flash-cpz.sh /dev/mmcblk0     # or /dev/sdX
```

Watch for `snapshot rewritten: N bytes (backup: N bytes)` — the numbers
must match; any `ERROR` line means the flash was aborted and your pre-flash
copy is safe in `cpz-cfg-backup-*`.
