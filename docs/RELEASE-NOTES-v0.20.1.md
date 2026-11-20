# CPZ-Alpine v0.20.1 — first flashable release

This is the first public, flashable CPZ-Alpine image: a minimal Alpine
Linux 3.24 (aarch64/musl, OpenRC) for the M5Stack CardputerZero, with the
M5 APPLaunch launcher owning the internal LCD.

## What's new

- **First release image** with a complete flash package: compressed image,
  SHA-256, Linux/Windows/macOS flashers, and instructions.
- **Files** and **Camera** are preinstalled and enabled by default in the
  launcher carousel, between IP Panel and Calculator.
- **Camera MIPI-CSI works**: fixed the `/dev/dma_heap` permission, added the
  Raspberry Pi VC4 IPA/tuning (`libcamera-raspberrypi`) and the missing
  `rpi_apps.yaml` pipeline config. The `imx219` sensor is detected and the
  libcamera backend starts the preview.
- **Files opens `/home/cpz`** (not a nested `~/Files` directory).
- **Persistence**: Files content, camera media, Wi-Fi profiles, launcher
  settings and root config live under `/home/cpz` and friends, archived by
  `cpz-save` to `/cfg` and restored at boot.
- Linux flasher preserves `/cfg` across reflashes. Windows/macOS helpers
  preserve it on cards that already have the CPZ-Alpine partition table.

## Known issues

- **Windows/macOS clean installs have no `/cfg` partition.** The helpers
  only preserve an existing CPZ-Alpine layout; a blank/foreign card is a
  clean install. Use `flash-cpz.sh` on Linux once if you want persistence
  on a fresh card.
- The image is fixed-size (1.76 GiB raw). Space beyond the image on a
  larger card is not used yet.
- **Files video preview is unverified on the internal panel.** The player
  shells out to `ffmpeg`; audio/video playback needs a hardware pass.
- **Camera CJK glyphs may be missing**: the app logs that
  `NotoSansCJK-Regular.ttc` / `NotoSansCJK-Medium.ttc` are absent. Latin
  UI text is unaffected.
- HDMI stays dark until the HDMI app / desktop is started. This is
  intentional (no boot console or splash on HDMI).
- There is no app store, package manager UI, or updater in this image.
- Windows and macOS flashers have not been executed on those operating
  systems in this build environment; only their shared logic and the
  Linux flasher were tested.

## Untested / needs a hardware pass

- USB camera (no USB camera available during the build).
- Camera still capture, video recording, gallery playback and audio
  shutter on the real sensor (preview + libcamera backend were verified).
- Files browsing, copy/rename/delete, text/image preview, audio playback
  and video playback through the launcher UI.
- Windows `flash-cpz.bat` and macOS `flash-cpz.command` end-to-end.
- Long-running stability (Wi-Fi reconnect, sleep/power, repeated saves).
- Bluetooth and the on-demand HDMI desktop beyond the v0.19.0 checks.

## Flash

Use the ZIP asset from this release. The Linux flasher is recommended and
preserves `/cfg`; see `README.txt` inside the ZIP for Windows/macOS steps.

SHA-256 of the release ZIP is attached as
`cpz-alpine-0.20.1.zip.sha256`. The image checksum is inside the ZIP.