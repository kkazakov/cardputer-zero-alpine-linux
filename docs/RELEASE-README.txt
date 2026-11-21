CPZ-Alpine @VERSION@ - flashable release
================================================

This folder contains everything needed to write CPZ-Alpine to a microSD
card for the M5Stack CardputerZero. Keep the files together.

Contents
--------
  cpz-alpine-@VERSION@.img.gz          compressed image (1.76 GiB raw)
  cpz-alpine-@VERSION@.img.gz.sha256   SHA-256 checksum
  flash-cpz.sh                         Linux flasher (recommended)
  flash-cpz.bat                        Windows launcher (runs .ps1 as admin)
  flash-cpz.ps1                        Windows PowerShell implementation
  flash-cpz.command                    macOS double-click flasher
  README.txt                           this file
  RELEASE-NOTES.txt                    what is new / known issues / untested

Image SHA-256
-------------
@SHA256@  cpz-alpine-@VERSION@.img.gz

Use an 8 GB or larger microSD card. A card reader is required; do not use
the stock M5 card, and triple-check the target device before confirming.

Linux (recommended)
-------------------
The Linux script creates the CPZDATA persistence partition and preserves it
across reflashes: Wi-Fi profiles, files in /home/cpz, launcher settings and
camera media survive a reflash.

  sha256sum -c cpz-alpine-@VERSION@.img.gz.sha256
  lsblk                      # find the card, e.g. /dev/sdb (NOT /dev/sda)
                             # laptop reader: /dev/mmcblk0
  sudo ./flash-cpz.sh /dev/sdb
  # or: sudo ./flash-cpz.sh /dev/mmcblk0

The script also verifies the checksum, unmounts auto-mounted partitions,
creates CPZDATA at the fixed 4 GiB offset up to the end of the card, formats
it only when it is missing or corrupt, and grows its filesystem to the
partition.

Windows
-------
1. Extract the whole ZIP first (do not run from inside the ZIP viewer).
2. Right-click flash-cpz.bat and choose "Run as administrator".
3. Pick the physical disk number for the card (not your system disk) and
   type ERASE.
4. If Windows asks to format a partition afterwards, click Cancel.
5. Remove and re-insert the card before booting the device.

If the card already has the CPZ-Alpine layout from a previous flash, the
Windows script keeps the existing partition table and CPZDATA, so /cfg
survives the reflash. On a brand-new card the script writes only the OS;
the device then creates CPZDATA itself on the first boot and reboots once.
You will see the launcher, the device restarts, and the second boot is the
normal one — from then on it never reboots by itself. Same for a plain
`dd`, balenaEtcher or Raspberry Pi Imager write.

macOS
-----
1. Double-click flash-cpz.command. If Gatekeeper blocks it, right-click
   the file, choose Open, then Open again.
2. Pick the disk identifier (for example disk4, never disk0) and type ERASE.
3. Enter your administrator password when sudo asks.

The macOS script behaves the same as the Windows one: existing CPZDATA is
preserved, a blank card gets /cfg from the device on the first boot (one
extra reboot). Terminal must stay open until "done" appears.

First boot
----------
- The internal LCD stays dark for a few seconds, then the APPLaunch
  launcher appears (about 15 seconds on a normal card).
- If the card was written by anything other than flash-cpz.sh, the first
  boot ends with one automatic reboot while the device creates its /cfg
  partition. The second boot is the normal one.
- HDMI stays dark until you start the HDMI app / desktop. This is normal.
- SSH: root@<device-ip>, initial password "alpine". Change it after the
  first login. The serial console is on the 14-pin expansion UART at
  115200 baud.
- Join Wi-Fi from Settings -> Wi-Fi, or plug in Ethernet.

Persistence and updates
-----------------------
CPZDATA is mounted as /cfg and covers the rest of the card. `cpz-save` runs
hourly and can be run manually; `cpz-restore.start` restores the archive at
boot. Everything under /home/cpz (including files you create in the Files
app, camera photos and videos) is in that archive. Run `sudo cpz-save`
before pulling the card.

/cfg is sized to the card you flash, not to the image. If a card's /cfg is
smaller than its partition (for example it was flashed from a smaller card),
it grows on the next boot. To move to a bigger card, flash the bigger card.

Use the Linux flasher when you want to keep /cfg across a reflash;
Windows/macOS/Etcher writes keep it too when the card already has the
CPZ-Alpine partition table.

Checksum manually
-----------------
Linux:   sha256sum -c cpz-alpine-@VERSION@.img.gz.sha256
macOS:   shasum -a 256 -c cpz-alpine-@VERSION@.img.gz.sha256
Windows: Get-FileHash .\cpz-alpine-@VERSION@.img.gz -Algorithm SHA256

Troubleshooting
---------------
- "not a block device" (Linux): pass the whole disk (/dev/sdb), not a
  partition (/dev/sdb1).
- "Resource busy" / cannot unmount: close file managers and terminals
  using the card, then retry.
- Dark LCD but SSH works: check `rc-service applaunch status` and
  `/var/log/applaunch.log`.
- Camera says "MIPI-CSI camera unavailable": use the 0.20.1+ image; the
  release notes list the libcamera packages and dma-heap fix.
- The image is fixed-size (1.76 GiB); unallocated space on larger cards is
  not used yet.

Project: https://github.com/kkazakov/cardputer-zero-alpine-linux
Release: https://github.com/kkazakov/cardputer-zero-alpine-linux/releases

Built @DATE@.