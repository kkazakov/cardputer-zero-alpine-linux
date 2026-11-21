# CPZ-Alpine v0.21.7 — save seconds after a change, not minutes

v0.21.6 still failed the field test: flash → Wi-Fi/passwords → reflash
came back with defaults. On-device diagnosis showed why:

- `/cfg` **was** preserved across the flash (`Filesystem created` stayed
  at the earlier time).
- The archive on the card was from **15:45**; the changes were made after
  that, and the card was pulled / power was cut before the next 5-minute
  tick or a clean shutdown.
- The shutdown hook itself works (verified: the archive was rewritten at
  a clean reboot), and `cpz-restore` works when run by hand (a marker
  file came back).

So the remaining gap is time: a card pulled while the device is running
never gets a final save.

## What's new

- **`cpz-state-watch`** — a small root service started by `local.d`. It
  polls only the config paths every 5 s (`/etc/shadow`, the NM
  connection profiles, `/var/lib/tailscale/tailscaled.state`, the
  Tailscale/HDMI launcher preferences, `/root` and `/home/cpz` SSH keys,
  `/etc/hostname`, `/etc/hosts`, `wpa_supplicant.conf`, `/etc/apk/world`)
  and calls `cpz-save` as soon as one changes. A password change is on
  the card within ~5 s, without waiting for cron or a shutdown.
- **Previous-generation archive.** Before replacing `save.tar.gz`,
  `cpz-save` hardlinks the old one to `save.tar.gz.prev` (zero copy). If
  the new archive is ever unreadable, `cpz-restore` falls back to the
  previous generation instead of booting with defaults.
- **Restore trace.** `cpz-restore` appends one line per boot to
  `/cfg/cpz-restore.log` (`restoring save.tar.gz (N bytes)` / `done: N
  NetworkManager profile(s)`), so a failed restore is diagnosable after
  the fact — `logger` goes nowhere without a syslog daemon.
- **NetworkManager dispatcher** now runs `cpz-save` under `setsid`, so
  NM cannot kill the backgrounded save when the script exits. (It may
  have been doing exactly that, losing a freshly joined Wi-Fi profile.)
- Image verification checks the watcher, its start hook, the `.prev`
  hardlink and the restore log.

## Known issues

- The watcher covers **configuration**, not `/home/cpz` media. Photos and
  videos are still snapshotted by the 5-minute cron and at shutdown, so a
  card pulled mid-camera-session can lose recent media.
- A card pulled **during** a `cpz-save` write can still leave the archive
  incomplete; the `.prev` generation (or the 5-minute cron) is the
  fallback.
- `/cfg` must be mounted. If the flasher ever leaves p3 unformatted, the
  watcher cannot save anything; check `mountpoint /cfg`.

## Untested / needs a hardware pass

- **The full reported sequence on hardware with v0.21.7** was not run
  (the device is on the tailnet, but flashing happens on the desktop).
  Do: flash v0.21.7, join Wi-Fi, set passwords, `touch /etc/hosts`, wait
  8 s, confirm `/cfg/save.tar.gz` mtime moved **and**
  `/cfg/save.tar.gz.prev` appeared, then pull the card without a
  shutdown, reflash, boot, and verify the password/Wi-Fi/Tailscale came
  back.
- The watcher's 5 s poll was verified on the live device (a touched
  watched file produced a new archive and a `.prev` hardlink within 8 s),
  but the **boot-time start hook** has not been through a full reboot on
  this image.
- `/cfg/cpz-restore.log` was added after the last boot; the next boot is
  the first one that writes it.
