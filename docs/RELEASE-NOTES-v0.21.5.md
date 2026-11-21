# CPZ-Alpine v0.21.5 — flash-cpz.sh finds CPZDATA on mmcblk/nvme readers

Fixes one bug in the v0.21.4 release package: on a laptop's built-in SD
reader (`/dev/mmcblk0`, or an NVMe-style name), `flash-cpz.sh` wrote the
image, created the CPZDATA partition, then looked for the wrong partition
node and skipped formatting it.

The image content is otherwise identical to v0.21.4 (same launcher,
same Tailscale fix, same `/cfg` persistence).

## What's new

- **`flash-cpz.sh` handles device-class partition names.** Linux names
  the third partition `mmcblk0p3` / `nvme0n1p3` but `sda3`. The script
  built `PART="${DEV}3"`, so `/dev/mmcblk0` became `/dev/mmcblk03`:
  ```text
  WARNING: /dev/mmcblk03 did not appear — persistence unavailable this time.
  ```
  It then exited **0** and left `mmcblk0p3` as an unformatted partition.
  It only worked on `/dev/sdX` USB card readers.
  The suffix is now `p3` when the disk name ends in a digit, `3`
  otherwise.
- **The partition-node lookup retries for ~3 s** (udev can lag behind
  `partx`), and a node that still does not appear is a hard error with
  the exact manual command instead of a silent success.
- This is a **flasher-only** fix: the image is rebuilt only to keep the
  version/provenance consistent (`/etc/cpz-release` = 0.21.5). The
  v0.21.4 image has the same launcher/Tailscale/restore payload.

## Known issues

- **A card flashed with v0.21.4's flasher is still bootable.** The write
  itself succeeded; only the CPZDATA format was skipped. Finish it with:
  ```sh
  sudo partx -u /dev/mmcblk0
  sudo mkfs.ext4 -F -L CPZDATA /dev/mmcblk0p3
  ```
  or rerun the v0.21.5 flasher.
- The script still refuses to re-read a mounted partition table; it
  unmounts the target first. Close file managers that hold the card.
- Windows/macOS flashers are unchanged: on a blank/foreign card they
  still leave CPZDATA creation to the device's first boot (one extra
  reboot).
- Everything else from v0.21.4 applies (Tailscale OFF survives a reboot,
  `/var/lib/tailscale` survives a reflash, etc.).

## Untested / needs a hardware pass

- **The fixed flasher was exercised on the failing path only as far as
  the partition-node lookup**: the v0.21.4 run had already created
  `/dev/mmcblk0p3` (unformatted), which is exactly what the old script
  could not see. The v0.21.5 script is expected to detect
  `mmcblk0p3`, `fsck` it (fail), and `mkfs.ext4` it; a full fresh
  v0.21.5 flash from a blank card has not been run here.
- A **loop-device emulation** confirmed the `p`-suffix branch (the script
  looked for `/dev/loop12p3`, not `/dev/loop123`), but loop partition
  rescans are flaky and `mkfs` on the emulated node failed with `ENXIO`.
  The real `mmcblk` reader already exposes `mmcblk0p3`, so that step is
  the one to watch on the first real flash.
- No floppy/USB `/dev/sdX` regression test was run for this patch; the
  `sda3` branch is the unchanged old path.
- The v0.21.5 image's own boot was not re-run on the card; the rootfs is
  v0.21.4 plus the version string, and the image verification pass is
  clean.
