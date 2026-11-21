# CPZ-Alpine v0.21.9 — the three Settings bugs

The reflash itself was not losing `/cfg`: v0.21.8's restore log shows
`restoring save.tar.gz (23801 bytes)` → `done: 1 NetworkManager profile(s)`,
and the flasher's pre-write backup has the same Wi-Fi PSK and the same
`root`/`cpz` password hashes as the live system. What *was* lost were the
settings that never got written or applied in the first place. This release
fixes the three Settings pages.

## What's new

- **Settings → Screen → Brightness now works.** The backlight sysfs node is
  `0644 root:root`; the launcher runs as `cpz`, so every write failed with
  EACCES and the page reported "backlight write failed" while the value
  stayed at 75/100. A new `cpz-permissions.start` hook makes
  `/sys/class/backlight/backlight/brightness` (and the GPIO chips used for
  the power outputs) group `video` + `0660` at boot, so the launcher can
  write it. Verified live: writing 40 as `cpz` succeeded.
- **Settings → Speaker survives a reboot.** `cpz-audio.start` restored the
  build-time 86% mixer snapshot and ignored the saved setting. It now
  restores the snapshot and then applies `"volume"` from
  `~/.config/cardputerzero/config.json` to DACL/DACR (50% → 127/255),
  which is the value the page saves on commit.
- **Settings → Date & Time → Network time works.** The launcher's NTP path
  was systemd-timedated only (`timedatectl set-ntp`), and the page treated
  NTP as unavailable because the D-Bus property could not be read. Added
  `cpz-ntp` (busybox `ntpd` against `pool.ntp.org`, preference in
  `/var/lib/cpz/ntp`), a `cpz-ntp.start` boot hook, and the launcher
  fallbacks: `NtpGet` reads the preference when timedated is absent,
  `NtpSet` runs `cpz-ntp set 0|1` through the sudo helper.
  Verified live: `cpz-ntp set 1` started ntpd, `set 0` stopped it.

## Known issues / notes

- The Wi-Fi profile, password hashes, `/root`, `/home/cpz` and
  `/var/lib/tailscale` **were** restored by the v0.21.8 flash; the archived
  `config.json` was `{"dark_time": 60, "volume": 50}` — the settings you
  changed had not been saved by the UI. The pre-flash copy is still at
  `~/Downloads/cpz/cpz-alpine-0.21.8/cpz-cfg-backup-20261121-151258/` on
  `winmax2a`.
- The NTP toggle is a thin wrapper around busybox `ntpd`; it needs DNS and
  a reachable NTP peer, and there is no drift correction UI. Enabling it
  does not change the timezone.
- `/home/cpz` media remains on the 5-minute + shutdown snapshot.

## Untested / needs a hardware pass

- The `NtpGet`/`NtpSet` launcher changes were compiled and the helper was
  tested live, but the **Settings toggle itself** has not been clicked on
  this image yet.
- The brightness fix was validated by writing the sysfs file as `cpz` on
  the running v0.21.8 system; the v0.21.9 image's `cpz-permissions.start`
  has not been through a fresh boot.
- The volume boot apply was validated by parsing the live config and
  setting DACL/DACR by hand; the rebuilt `cpz-audio.start` has not run at
  boot yet.
