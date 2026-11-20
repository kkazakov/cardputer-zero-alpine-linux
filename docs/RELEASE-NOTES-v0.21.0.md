# CPZ-Alpine v0.21.0 — `/cfg` covers the whole card, on every flash route

Alpine Linux 3.24 (aarch64/musl, OpenRC) for the M5Stack CardputerZero,
with the M5 APPLaunch launcher owning the internal LCD. This release
changes only how the persistence partition is created — no UI or app
changes over v0.20.1.

## What's new

- **`/cfg` (CPZDATA) is provisioned by the device.** A card written with
  `dd`, Raspberry Pi Imager, balenaEtcher, `flash-cpz.bat` or
  `flash-cpz.command` now gets its persistence partition too: on the first
  boot the device appends the CPZDATA entry up to the end of the card,
  reboots once, and formats it. One extra reboot on a brand-new card;
  nothing to do on the desktop.
- **`/cfg` is sized to the card, not to the image.** The partition starts at
  the fixed 4 GiB offset and runs to the end of the card, and the ext4
  filesystem is grown to the partition — at flash time by `flash-cpz.sh`,
  on the next boot by the device if a card's filesystem is smaller than its
  partition (e.g. a card that was flashed from a smaller card).
- **The Linux flasher bug is fixed.** `flash-cpz.sh` deletes a stale CPZDATA
  entry before appending the new one; v0.20.1 passed `--no-update`, which
  sfdisk does not have, so the delete always failed silently and a reflash
  created an overlapping partition entry.
- **The image now ships `sfdisk`, `e2fsprogs`, `e2fsprogs-extra` and
  `blkid`** — the tools the device needs to do this itself.

## How the first boot looks (dd / Imager / Etcher / Windows / macOS)

1. Normal boot, launcher appears, everything works.
2. The device reboots by itself (it just wrote a new partition table and
   the kernel can only see it after a reboot).
3. Second boot: `/cfg` is created, and this is the final state. It never
   reboots by itself again.

`flash-cpz.sh` cards skip step 2 — `/cfg` is already there.

## Known issues

- **One extra reboot on the very first boot of a card that was not written
  by `flash-cpz.sh`.** This is inherent: the kernel refuses to re-read the
  partition table of a disk whose partitions are mounted, so the geometry
  change and the filesystem creation cannot happen in the same boot.
- **The device never shrinks.** A card can be reflashed to a bigger card
  and `/cfg` will cover it; a bigger card cannot be "un-grown" without
  reformatting `/cfg`.
- **Files video preview is unverified on the internal panel.** The player
  shells out to `ffmpeg`; playback needs a hardware pass.
- **Camera CJK glyphs may be missing** (`NotoSansCJK` not installed). Latin
  UI text is unaffected.
- HDMI stays dark until the HDMI app / desktop is started. Intentional.
- No app store, package manager UI or updater in this image.
- Windows and macOS flashers have not been executed on those operating
  systems in this build environment; only their shared logic and the Linux
  flasher were tested.

## Untested / needs a hardware pass

- **The v0.21.0 first-boot flow on real hardware.** The device-side logic
  was verified in a container simulation (real loop devices, real
  `mkfs.ext4`/`resize2fs`, faked `/sys/block/mmcblk0`, stubbed `reboot`)
  across ten scenarios — fresh card, extend, already-grown, foreign
  partition table, smaller card, healthy card — but **not on the device**.
  See `docs/FLASH-AND-TEST.md`, item **T2f**.
- Repeated reflashes keeping `/cfg/save.tar.gz` (Windows/macOS route).
- USB camera (no USB camera available during the build).
- Camera still capture, video recording, gallery playback on the real sensor.
- Files browsing, copy/rename/delete, preview, audio and video playback
  through the launcher UI.
- Long-running stability (Wi-Fi reconnect, sleep/power, repeated saves).

## Flash

Use the ZIP asset from this release. The Linux flasher is still the
recommended route — it provisions `/cfg` offline and preserves it across
reflashes; the other routes work and cost one extra reboot on a new card.
See `README.txt` inside the ZIP.

SHA-256 of the release ZIP is attached as `cpz-alpine-0.21.0.zip.sha256`.
The image checksum is inside the ZIP.
