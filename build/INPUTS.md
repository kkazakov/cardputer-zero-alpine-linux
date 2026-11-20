# build/INPUTS.md — pinned build inputs (v0.20.0)

Everything this build consumes, with content hashes. Reproduce by
fetching these exact artifacts; the build is deterministic against them.

## APPLaunch launcher (v0.17+)

- Repository: `launcher/` — a checkout of
  https://github.com/kkazakov/cardputer-zero-launcher-alpine, **branch
  `alpine`** (the fork of CardputerZero/launcher; its `master` tracks
  upstream untouched). The image build records the exact commit in the
  verification report; `build/25-launcher.sh` builds it.
- Built natively inside `linux/arm64 alpine:3.24` (musl) — the same
  release as the rootfs, so the binary's dynamic link set (freetype,
  libcurl, libinput, libxkbcommon, udev, gio, libstdc++) resolves
  against exactly the image's packages.
- Submodules at upstream pins: `SDK` = m5stack/M5Stack_Linux_Libs
  (`1846503d…`), `projects/Calculator` = CardputerZero/Calculator
  (`946c778e…`).
- `projects/Calculator` carries one build-time patch,
  `launcher/deploy/alpine/patches/calculator-native-fbdev.patch`
  (upstream hardwires every non-cross Calculator build to the SDL
  simulator; the patch adds the native FBDEV+EVDEV path). Applied
  idempotently by the build; the submodule pin is untouched.
- Launcher SYM keymap: `rootfs-overlay/usr/share/keymaps/
  tca8418_keypad_m5stack_keymap.map` — generated from the same measured
  keycap legends as `cpz-sym-keymap.map` (the harvest's stock map prints
  wrong symbols on rows q..m and is deliberately overridden).

## Files and Camera apps (v0.20.0)

Built natively (aarch64/musl) by `build/26-apps.sh` in the persistent
`cpz-apps-build` container; sources are cloned under `build/apps-src/`
(gitignored) at these pins:

- Files: https://github.com/CardputerZero/Files
  commit `af673336af3aeb3281c20575d2436b93ea4353f9` (v1.0.3 tree)
  - dependencies (from its `repos.json`): lvgl `v9.5.0`, spdlog
    `v1.17.0`, smooth_ui_toolkit `v2.13.0`, miniaudio `0.11.25`,
    box2d `v3.1.1`
  - built with `FILES_USE_SDL=OFF`, `FILES_USE_PULSEAUDIO=OFF` (the
    image has ALSA but no PulseAudio daemon); video preview shells out
    to the image's `ffmpeg`
- Camera: https://github.com/CardputerZero/Camera tag `v1.0.2`
  commit `54885137f52a888d8d194fd9e1beefbd68b1a999`
  - pinned to 1.0.2 because Camera 1.0.3+ requires libcamera >= 0.7.2
    (1.0.4 requires 0.8.0) while Alpine 3.24 ships libcamera 0.7.1
  - one build patch: `build/patches/camera-native-musl.patch` removes
    `/usr/include` from its target include lists, because an explicit
    `-isystem /usr/include` breaks Alpine musl's fortify
    `include_next <stdlib.h>` chain
  - runtime assets in `/usr/share/camera_app/{fonts,audio,images}` plus
    the compatibility `/usr/share/CameraApp/assets/{fonts,audio}`

## M5 stock CardputerZero image (Phase-A BSP source)

- URL: https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/cardputerzero-trixie-arm64-latest.img.xz
  (a.k.a. "latest" pointer on M5's OSS bucket — **can move**; the hash below is the pin)
- sha256: `1b1002f7def184d6ca18d973f8b94622ccbe6552f3159cf1789ea955e833ed0a`
- size: 1,458,604,272 bytes (xz) → 6,576,668,672 bytes raw
- Last-Modified on server: 2026-06-08
- Contents basis: Raspberry Pi OS Trixie arm64, kernel `6.18.33+rpt-rpi-v8`
  (+ unused `rpi-2712` tree), M5 legacy `cardputerzero-overlay` DTBO,
  M5 out-of-tree modules in `/lib/modules/…/extra/`, custom VideoCore
  `start.elf`/`fixup.dat` pair, u-boot.bin boot chain (which we drop).

## Alpine Linux base

- Docker image: `alpine:3.24` (linux/arm64) — running release 3.24.4
- apk repositories: `https://dl-cdn.alpinelinux.org/alpine/v3.24/{main,community}`
- apk-tools 3.0.9, mkinitfs 3.14.1, eudev 3.2.14-r6, kbd 2.8.0, wpa_supplicant 2.11-r4

## Console font

- Terminus 6×12 Unicode (`ter-u12n.psf.gz`) from the Alpine `terminus-font`
  package (v0.5+). 53×14 characters on the 320×170 panel.
- v0.1..v0.4 used Spleentt 5×8 (`SpleenttMedium.psf`) from
  https://github.com/tommythorn/spleentt-5x8-font — 64×21 chars, too small
  to read comfortably; superseded.
- sha256(Spleentt psf): `77a8d654f26e1bcab1e7452869f968bc36a2d0b16f0c49c34a8b31e6ff886c72`
- sha256(Spleentt LICENSE): `317e47dadb2ed19a915719c7096548a3ef03e72a0e2fc54cc0e30e0f68299282`

## Battery-gauge driver rebuild (v0.5.0 — replaces stock bq27xxx)

The stock image's compiled `extra/bq27xxx_battery*.ko` predates M5's own
BQ27220 support (verified: binary lacks `ti,bq27220`), while the stock
`overlays/bq27220.dtbo` declares `ti,bq27210` — wrong register map, every
gauge read failed with -121 (EREMOTEIO). Rebuilt from M5's vendor source
against the exact distro kernel headers (MODVERSIONS on → CRCs must match):

- Source: `vendor/m5stack-linux-dtoverlays/modules/bq27220-1.0/` (GPL, M5)
  - md5(bq27xxx_battery.ko)    = `17ccac9cfe3baf13b73dcab2a925edda`
  - md5(bq27xxx_battery_i2c.ko)= `83b1d35afec6deda86b1965ef84defff`
  - vermagic: `6.18.33+rpt-rpi-v8 SMP preempt mod_unload modversions aarch64`
- Headers (archive.raspberrypi.com, trixie, all `1:6.18.33-1+rpt1`):
  - `linux-headers-6.18.33+rpt-common-rpi` (9,262,452 B)
  - `linux-headers-6.18.33+rpt-rpi-v8` (436,252 B)
  - `linux-kbuild-6.18.33+rpt` (1,397,376 B) — host kbuild tools
  - Build tweaks (documented, mechanical): patch the two absolute
    `/usr/src/linux-headers-*` paths in the v8 Makefile, and strip the
    Debian `.kernelvariables` cross-CC overrides (build with native gcc-14).
- New `overlays/bq27220.dtbo` = M5's `bq27220_v5.dts` compiled
  (`ti,bq27220`, 1750 mAh design capacity, external NTC).
- `modules.alias` regenerated (udev autoload alias for `ti,bq27220`).

## M5 kernel/driver source (GPL, reference)

- https://github.com/m5stack/m5stack-linux-dtoverlays (out-of-tree modules + DTS;
  bq27220-1.0 IS consumed by the v0.5 build — see above)
- https://github.com/CardputerZero/pi-gen branch `cardputerzero_v1.1`
  (stock image build: sha256-pinned kernel 6.18.39 debs — the *newer*
  generation than the OSS "latest" image; our Phase A tracks the image)
- Kernel .debs (if needed for Phase B/C): archive.raspberrypi.com, pinned by
  the sha256 manifest in pi-gen `stage0/02-firmware/files/kernel-packages.sha256`

## Notes

- The OSS "latest" image lags pi-gen v1.1 (6.18.33 vs 6.18.39, u-boot vs
  direct boot, combined vs split overlays). We replicate the *shipped*
  image's kernel + DTBO + modules bit-exactly and adopt v1.1's *boot
  design* (no u-boot) — each choice is documented in build/boot-config/.
- Where does the 93-byte panel init blob fit? The v1.1 (split-overlay,
  panel-mipi-dbi) generation loads `cardputerzero,st7789v_lcd.bin` from
  /lib/firmware; the shipped 6.18.33 generation has the init sequence
  compiled into `st7789v_m5stack.ko` (verified: no firmware tag on the
  module, no blob in the stock rootfs).
