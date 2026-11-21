# CPZ-Alpine v0.21.14 — custom timezone

## What's new

- `cpz-timezone` helper:
  - `cpz-timezone status` — current zone
  - `cpz-timezone list` — all available `Region/City` zones (tzdata)
  - `sudo cpz-timezone set <Region>/<City>` — sets `/etc/localtime` and
    `/etc/timezone`, then snapshots `/cfg`
- The zone name is saved to `/cfg/timezone`, carried by the flasher's
  pre-flash backup and write-back, and re-applied by `cpz-restore` **before**
  services start — so the choice survives a reflash instead of resetting to
  the build default (Europe/Sofia).

## Manual equivalent (any version)

```sh
sudo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
echo "Asia/Tokyo" | sudo tee /etc/timezone
```

This only lasts until the next reflash without v0.21.14.

## Untested / needs a hardware pass

- Compiled/checked in the container; not yet flashed. Verify:
  `sudo cpz-timezone set Asia/Tokyo`, reboot, `cpz-timezone status` and
  `date` keep the zone, then reflash and check it again.
