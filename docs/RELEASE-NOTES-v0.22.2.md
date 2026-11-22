# CPZ-Alpine v0.22.2 — compass sensor + launcher fixes

This release adds BMM150 magnetometer hardware support so the Compass app
can read heading from the onboard sensor, and bakes in five launcher fixes
from the `alpine` fork that improve Tailscale reliability, NTP/time
handling, and package-install feedback on OpenRC.

## What's new

**Compass (BMM150 magnetometer) — hardware support**

- Built `bmc150_magn.ko`, `bmc150_magn_bmi270.ko` and `bmc150_magn_i2c.ko`
  from M5 vendor source against the shipped 6.18.33+rpt-rpi-v8 kernel.
- Added `bmi270_bmm150_overlay.dtbo` device-tree overlay that creates the
  BMM150 platform device on the BMI270 auxiliary I2C bus.
- The Compass app now sees the magnetometer at `iio:device2` and computes
  heading from combined accelerometer + magnetometer data through the
  Linux IIO sysfs interface.

**Launcher fixes (from the `alpine` fork)**

- **Tailscale availability race**: the availability check now handles
  profile-state races (the card no longer flickers or disappears while
  `tailscaled` is writing its state file).
- **NTP on OpenRC**: `NtpSet` and `TimeSet` now route through `sudo -n`
  directly instead of the systemd sudo-prompt coordinator, so the
  network-time toggle and manual time entry actually work.
- **Package-install feedback**: the Settings → packages reinstall flow
  now shows a launcher toast ("Installing packages…" / "Packages ready")
  instead of working silently in the background.
- **NTP defaults to disabled on OpenRC**: fresh installs no longer try to
  sync time over a network that isn't up yet.
- **Tailscale toggle saves immediately**: `/cfg` is snapshotted right
  after a tunnel toggle, so pulling the card right after switching
  Tailscale on or off preserves the choice.

**Developer tools**

- `build/build-app-package.sh` and `build/install-via-ssh.sh` scripts
  for building and deploying app bundles to a running device over SSH.
- README updated with the app-building workflow.

## Known issues

- A card pulled while a `cpz-save` write is in flight can still lose that
  save (up to the previous generation in `save.tar.gz.prev`).
- The Compass app needs both BMI270 (accel) and BMM150 (mag) sensors
  present; if the overlay fails to load, the app shows "Compass sensors
  unavailable" and retries every 5 s.
- Packages that add their own OpenRC service need a start hook (Tailscale
  has one; arbitrary third-party services may need `rc-update add` after
  the reinstall).

## Untested / needs a hardware pass

- Compass heading accuracy on real hardware (verified sensors appear at
  the correct IIO paths — raw magnetometer values change with device
  orientation — but full heading calibration against a known reference has
  not been done on this build).
- Camera stills/video after the libcamera chain was unchanged in this
  release.

## Flash

Download the ZIP, verify the SHA-256, then:

```sh
sudo ./flash-cpz.sh /dev/mmcblk0     # or /dev/sdX
```

Watch for `snapshot rewritten: N bytes (backup: N bytes)` — the numbers
must match; any `ERROR` line means the flash was aborted and your pre-flash
copy is safe in `cpz-cfg-backup-*`.