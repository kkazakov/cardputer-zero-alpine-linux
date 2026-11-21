# CPZ-Alpine v0.21.6 — persistence keeps up with setup

Fixes the reported failure where a card was flashed, Wi-Fi/Tailscale/
passwords were configured, and the next reflash came back with defaults.
There were two independent ways to lose the data, and both are fixed.

## What's new

- **`cpz-save` now runs on every meaningful change, not just hourly.**
  The old schedule was one run per hour (plus manual). A setup session
  that ended in a poweroff + reflash inside that hour lost everything:
  `/etc/shadow` (password), `/root` (SSH keys), the NetworkManager
  profiles (Wi-Fi), `/var/lib/tailscale` and the launcher preferences.
  Triggers now are:
  - **every 5 minutes** (`/etc/crontabs/root`);
  - **as soon as a NetworkManager connection comes up or goes down**
    (`/etc/NetworkManager/dispatcher.d/90-cpz-save`), which captures a
    freshly joined Wi-Fi profile within seconds;
  - **after the launcher's Tailscale toggle** (the page calls
    `cpz-save` behind `apply on|off`);
  - **at shutdown/reboot** (`/etc/local.d/cpz-save.stop`, run by the
    `local` service before the filesystems go away) — the one that
    catches "power off, then pull the card".
  All triggers are serialized with `/run/cpz-save.lock`, so overlapping
  runs cannot corrupt `save.tar.gz`.
- **`flash-cpz.sh` no longer formats a valid-but-dirty CPZDATA.**
  `fsck.ext4 -n` returns non-zero for a journal that needs replay; the
  old code treated any non-zero as "corrupt" and ran `mkfs.ext4`. A
  reflash after an unclean shutdown therefore wiped a perfectly good
  `/cfg`. The flasher now:
  1. checks `blkid` says `ext4`;
  2. runs `e2fsck -f -y` to replay/repair;
  3. keeps the filesystem if `fsck -n` then passes;
  4. formats only when the filesystem is absent/not ext4 or repair fails.
- **cpz-save logs a visible failure** when `/cfg` is not mounted
  (`logger -t cpz-save`), instead of failing silently to /dev/null.

## Known issues

- **Data that was never saved cannot be recovered.** If the first setup
  was done before v0.21.6 and the card was reflashed without a manual
  `cpz-save`, that snapshot was never written. The old card's `/cfg` may
  still hold an older snapshot; the new 64 GB card's `/cfg` only has
  whatever was saved there.
- **A card must have a mounted `/cfg` for any of this to work.** If the
  flasher skipped the CPZDATA format (v0.21.4 bug) the card boots but
  never persists. v0.21.5/higher format it; check with
  `mountpoint /cfg && ls -l /cfg`.
- The shutdown hook only runs on a **clean** `reboot`/`poweroff`. Pulling
  the card or cutting power still loses anything newer than the last
  5-minute snapshot (at most 5 minutes now, not an hour).
- Windows/macOS flashers are unchanged.

## Untested / needs a hardware pass

- **The exact reported sequence was not re-run on the device**: flash,
  configure Wi-Fi + Tailscale + password, reflash, verify restore. The
  device is tailnet-only and was offline at the time of this build. The
  fix was verified by inspection of each trigger and by the clean image
  verification pass; the next hardware pass should do:
  1. set up Wi-Fi + Tailscale + a password;
  2. wait ~6 minutes (or run `sudo cpz-save`);
  3. poweroff (not pull), reflash with v0.21.6, boot;
  4. confirm `/etc/shadow`, `/root/.ssh/authorized_keys`, the NM profile
     and `/var/lib/tailscale` came back.
- **The dirty-CPZDATA repair path** (`blkid` → `e2fsck -f -y` → keep)
  was not exercised against a real dirty ext4 on the card; only the
  code path and syntax were checked.
- The 5-minute cron, NM dispatcher and shutdown hook were not observed
  running on hardware in this build.
