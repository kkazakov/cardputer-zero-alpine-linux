# FLASH AND TEST — CPZ-Alpine 0.5.0

This is the first bootable CPZ-Alpine image. It was built entirely offline
from M5's own stock image (Phase-A kernel graft) — **it has never touched
real hardware**. Everything below marked [TEST] is unverified until you run it.

## What you're flashing

- `images/cpz-alpine-0.1.0.img.gz` (+ `.sha256`) — 1.8 GiB raw image:
  FAT32 boot (256 MiB) + ext4 root (1.5 GiB), MBR disk id `0x10c0ffee`
- Base: Alpine Linux 3.24 aarch64, musl + BusyBox + OpenRC, **no systemd**
- Kernel: M5 stock `6.18.33+rpt-rpi-v8` (bit-exact from the factory image,
  incl. the M5 out-of-tree modules: panel, keypad, audio, gauge, IMU)
- Boot: stock VideoCore firmware + stock DTB set + stock
  `cardputerzero-overlay` — **u-boot removed** (direct kernel8.img boot,
  the direction of M5's current pi-gen branch)

## Flashing

```sh
sha256sum -c cpz-alpine-0.1.0.img.gz.sha256     # verify download
# /dev/sdX = the LAB microSD card (NOT the stock card, NOT a disk!)
lsblk                                          # triple-check sizes
gunzip -c cpz-alpine-0.1.0.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Or use Raspberry Pi Imager / balenaEtcher with the `.img.gz` directly.

The image is fixed-size (1.8 GiB); leftover space on a bigger card is
unused for now (fine for testing; we'll auto-grow later).

## What should happen on first boot

1. No splash. The LCD stays dark for a few seconds (kernel + OpenRC
   starting — this build loads the panel driver from the rootfs, not an
   initramfs — that's the accepted R2 fallback: "console appears seconds
   later, still usable").
2. Then boot text should appear on the **internal LCD** (fbcon on fb0,
   64×21 chars, Spleentt 5×8) and keep scrolling to a login prompt.

   `cpz login:` — log in as **root**, password **alpine**
   (also user **cpz** / **alpine**, member of wheel).
3. The shell prompt shows battery % + SoC temp once the gauge probes:
   `[100% 47.0°C ~]#`

## Test checklist (in order)

- [ ] **T1 — LCD console**: login prompt appears on the internal screen.
      If it's blank: does the backlight come on? Can you switch VTs?
      (Alt+F2 from a USB keyboard on tty2.)
- [ ] **T2 — keyboard**: type on the CPZ keyboard. A–Z, 0–9, punctuation,
      Enter, Backspace, arrows. The SYM layer: `/` should be **SYM+N**
      (per printed legends), `!` SYM+1 etc.
- [ ] **T3 — serial rescue, no adapter needed**: if the LCD is ever dark,
      use the USB-C port as a serial gadget. Apply
      `build/offline-fix/fix-card.sh` to the flashed card from the desktop
      (auto-detects the `CPZBOOT` partition): it adds `dwc2,dr_mode=peripheral`
      + the `g_serial` gadget, then the USB-C cable to the desktop shows
      `/dev/ttyACM0` — `screen /dev/ttyACM0 115200`. For a *working* v0.5
      boot this is not needed at all.
- [ ] **T4 — USB host**: plug a USB flash drive into the USB-A port →
      `dmesg | tail` shows usb-storage; plug a USB keyboard → types.
- [ ] **T5 — Ethernet**: **unsupported in Phase A** — the stock kernel has
      no SR9900A driver (`sr9900` absent). Cable stays dark; tracked for a
      Phase-B kernel build.
- [ ] **T6 — SSH**: from your LAN: `ssh root@<ip>` (password `alpine`).
      Key-only lockdown comes later (S09) — don't expose this image.
- [ ] **T7 — Wi-Fi chips present**: `ip a` shows wlan0 (unconfigured —
      see below to join a network). `iw dev wlan0 scan | grep SSID` should
      list networks.
- [ ] **T8 — battery**: `cat /sys/class/power_supply/bq27220-0/capacity`
      now reports a real percentage (v0.5 rebuilt the gauge driver with
      true BQ27220 support). `power_now` / `voltage_now` should read sane
      values, and `dmesg | grep bq27` must show **no** `-121` errors.
- [ ] **T8b — keyboard LEDs**: the three SHIFT/FN/SYM LEDs must be OFF at
      idle (they used to cycle endlessly). Press SHIFT → its LED lights
      while held; double-press behavior (locked mode) is the driver FSM's.
- [ ] **T9 — audio**: `speaker-test -c2 -twav` (ES8389 speaker path) and
      `alsamixer` (F6 to pick the es8389 card).
- [ ] **T10 — HDMI**: plug into a monitor — the desktop *does not* start
      (this build has no compositor at all). But check `dmesg | grep vc4`
      shows the HDMI connector detected.

## Wi-Fi on the device (post-flash)

```sh
vi /etc/wpa_supplicant/wpa_supplicant.conf    # add your network block
vi /etc/network/interfaces                   # uncomment wlan0 stanza
rc-service networking restart
```

## If it doesn't boot

Ranked escape hatches:

1. **Serial console** (T3) — the kernel logs everything to `serial0`
   (mini-UART, 115200 8N1) even when the display stack fails.
2. **Stock card**: untouched — the factory OS restores the device in
   one flash.
3. Boot with HDMI: this build gives HDMI a KMS console via vc4
   (`console=tty1` only claims the LCD) — a monitor may show *something*
   even mid-failure. [TEST]

Capture for me: `dmesg` output (via serial or SSH), a photo of whatever
the LCD shows (including "nothing"), and whether the backlight glows.

## Known deviations from PLAN.md (v0.1, all documented in build/)

- No initramfs yet (R2 fallback; mkinitfs config staged for S03)
- No HDMI desktop (S08), no triggerhappy (not packaged in Alpine 3.24,
  S04 risk — vendoring or an evdev-script stopgap comes later)
- Wi-Fi/BT: firmware + services in place, BT attach script not yet (S05)
- Boot is verbose on purpose (no `quiet`) — first-flash observability
  beats boot-time budgets until S09.
