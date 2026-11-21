# CPZ-Alpine v0.21.10 — the archive the flasher backed up is the one that boots

## What's new

- **The flasher writes the pre-flash `/cfg` snapshot back.** This is the
  real cause of the Wi-Fi/Tailscale loss in v0.21.9: the flasher's backup
  held a **30,346-byte** `save.tar.gz` (with `var/lib/tailscale`,
  `etc/apk/world` and the NM profile), but the boot restored a
  **23,527-byte** older one. The e2fsck journal replay/repair in the flash
  path had reverted the last (not fully committed) save. The flasher now
  mounts `/cfg` read-write after the resize and copies the backed-up
  `save.tar.gz`, `.prev`, `shadow-users`, `pkglist.txt` and `ntp` back, so
  the newest complete snapshot is exactly what the device boots.
  (`cpz-save` already calls `sync`; the revert was in the repair path, not
  in the save itself.)
- **Date & Time NTP is usable.** `NtpGet` returned "unavailable" when
  `/var/lib/cpz/ntp` did not exist, which greyed out both the NTP toggle
  and manual time. It now defaults to **disabled but available**, reads
  `/cfg/ntp` (falling back to `/var/lib/cpz/ntp`), and the preference is
  stored in `/cfg` so it survives a reflash. `NtpSet` drives
  `cpz-ntp set 0|1` (busybox `ntpd`). Manual time uses the existing
  `date -s … ; hwclock -w` privileged path, which was verified live
  (`date -s` and `hwclock -w` both return 0).
- The flasher backup/re-copy also carries `/cfg/ntp`.

## Known issues

- The re-copy assumes the backup taken before the write is the newest
  complete snapshot. If the pre-write mount itself had to replay a journal
  that reverted the archive, the backup will be that older state too; the
  `.prev` generation and the `cpz-cfg-backup-*` directory remain the
  recovery path.
- NTP still needs DNS and a reachable `pool.ntp.org`; there is no drift or
  server-selection UI.
- `/home/cpz` media remains on the 5-minute + shutdown snapshot.

## Untested / needs a hardware pass

- The flasher re-copy was not exercised on a real card in this build; it
  is a plain mount + `cp -p` + `sync` + umount of the same partition the
  pre-check already mounted read-only.
- The NTP toggle and manual-time commit on the rebuilt launcher have not
  been clicked on hardware; the helper and the `date`/`hwclock` commands
  were verified live on v0.21.9.
- The brightness/volume fixes from v0.21.9 are unchanged.

## Tailscale package reinstall

`cpz-wifi.start` used to run `apk add $(cat /cfg/pkglist.txt)` once,
immediately at boot, before Wi-Fi was associated; the install failed and
the package (Tailscale) stayed missing until it was installed by hand. It
now retries up to 18 times at 10 s intervals (~3 min), the same window
`cpz-tailscale-boot.start` waits for the binary. The package list and the
node state are in the pre-flash snapshot that the flasher now writes back.

## Custom and local packages

`/etc/apk/world` restores packages that come from a **reachable repository**
(`tailscale`, `tailscale-openrc`, …). It does **not** restore a local `.apk`
installed with `apk add /path/foo.apk`: only the name is in world, and the
file is not in any repo. v0.21.10 now saves and restores the rest of the
package state:

- `/cfg/world` — explicit package names (already added in this build).
- `/cfg/repositories` — `/etc/apk/repositories`, so a third-party repo is
  configured again before the install.
- `/cfg/apk-keys/` — `/etc/apk/keys`, for a signed custom repo.
- `/cfg/apk/*.apk` — local package files. The boot hook installs them with
  `--allow-untrusted` **before** processing world.
- `sudo cpz-apk add /path/foo.apk` — installs a local package, copies it to
  `/cfg/apk/`, and snapshots immediately.
- `/run/cpz-pkg.status` (`pending N` → `installing N` → `ok|failed`) and
  `/var/log/cpz-pkg.log`; the launcher polls the status and shows
  "Installing packages…" / "Packages ready" / "Package install failed".
