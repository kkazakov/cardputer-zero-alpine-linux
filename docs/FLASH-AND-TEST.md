# FLASH AND TEST — CPZ-Alpine 0.17.0

Built offline from M5's own stock image (Phase-A kernel graft). Versions
through v0.16 are **hardware-verified** per the README table; items marked
[TEST] below are new in this image and need one device pass.

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
   initramfs — that's the accepted R2 fallback: "UI appears seconds
   later, still usable").
2. Then the **APPLaunch launcher UI** takes over the internal LCD
   (v0.17: the panel belongs to the launcher, OpenRC `applaunch`
   service; the kernel console lives on HDMI/serial, `fbcon=map:0` —
   exactly the stock M5 image's split). You get the status bar (clock,
   battery, Wi-Fi state) over the app carousel. No login prompt on
   the panel; the console login is root/**alpine** on HDMI (tty1) or
   serial0 when debugging.
3. Wi-Fi joins automatically when an NM profile is baked (built from
   `build/wifi-secret`) — otherwise join from Settings → Wi-Fi.

## Test checklist (in order)

- [ ] **T1 — launcher on LCD**: the APPLaunch carousel appears on the
      internal screen within ~15 s of power-on. Cards cycle ←/→
      (or Z/X); Enter opens, ESC backs out / long-press returns home.
      The status bar shows the clock and a battery percentage.
      If the panel is dark: check `rc-service applaunch status` over
      SSH — `/var/log/applaunch.log` carries the launcher's stderr.
- [ ] **T1b — console split**: with HDMI plugged, tty1 shows the login
      (`root`/**alpine**); the LCD never flickers when the console
      redraws (kernel console is on HDMI, not on the launcher's fb).
- [ ] **T2 — keyboard (through the launcher)** [TEST]: ←/→ (Z/X) cycle the
      carousel; Enter opens the focused card; ESC backs out, long-press
      ESC returns home from anywhere. The SYM layer: open the **CLI**
      terminal card and type — `/` should be **SYM+N** (per printed
      legends), `!` SYM+1 etc.; SHIFT/FN modifiers behave per keycap.
      The launcher reads raw evdev and maps the SYM layer from
      `/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map` — the same
      field measurements as the console map.
- [ ] **T2b — Calculator** [TEST]: open the Calculator card; digits,
      operators, `=` compute; ESC (long-press) returns to the carousel.
- [ ] **T2c — Settings** [TEST]: Settings → Screen → Brightness steps the
      backlight; Speaker → volume keys work (ES8389 via ALSA); Wi-Fi →
      Networks lists APs and joins with a password (NetworkManager
      writes the profile; a reboot rejoins automatically); Date & Time →
      Set Manually moves the status-bar clock and *Write RTC?* persists
      it across a reboot. The System menu shows Storage / Licenses /
      Reboot but NO Software-updater page, and no Developer/ADB section —
      those are RPi-OS-only and hidden on Alpine.
- [ ] **T3 — serial rescue, no adapter needed**: if the LCD is ever dark,
      use the USB-C port as a serial gadget. Apply
      `build/offline-fix/fix-card.sh` to the flashed card from the desktop
      (auto-detects the `CPZBOOT` partition): it adds `dwc2,dr_mode=peripheral`
      + the `g_serial` gadget, then the USB-C cable to the desktop shows
      `/dev/ttyACM0` — `screen /dev/ttyACM0 115200`. For a *working* v0.5
      boot this is not needed at all.
- [ ] **T4 — USB host**: plug a USB flash drive into the USB-A port →
      `dmesg | tail` shows usb-storage; plug a USB keyboard → types.
- [ ] **T5 — Ethernet**: cable in → `ip a` shows eth0 with a DHCP lease;
      `ping -I eth0 -c3 1.1.1.1`. Since v0.12.2 the SR9900A is driven
      by a patched r8152 (mainline ID 0x0fe6:0x9900), dwc2 in host
      mode — field-verified on hardware. (The USB-C serial gadget was
      retired for host mode; Wi-Fi/Ethernet SSH is the remote path.)
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
- [ ] **T10 — HDMI desktop (on demand)**: plug into a monitor. Nothing
      starts by itself (hotplug prints an "ask" notice on the LCD).
      Run `cpz-desktop start`: sway + waybar + foot come up in ~5 s,
      ~90 MiB resident; Super+Enter terminal, Super+d launcher,
      Super+Shift+e exits. `cpz-desktop stop` reclaims the RAM. The
      internal LCD console is untouched throughout (fbtft is not a
      KMS output). Internal keyboard types — v0.14.1 assigns it to
      seat0 (M5's stock rule exiles it to a private seat).
- [ ] **T11 — camera (field-verified method)**: with v4l-utils on the
      device (kept across reflashes by the persistence pkglist):
      ```sh
      v4l2-ctl -d /dev/video0 --set-fmt-video=width=3280,height=2464,pixelformat=pRAA
      v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=1 --stream-to=/tmp/frame.raw
      ```
      Pull `/tmp/frame.raw` off the device and convert host-side:
      `python3 build/tools/debayer-srggb10.py frame.raw camera-test.jpg`.
      Healthy output: 10-bit stats using the full 0–1023 range.
- [ ] **T12 — Bluetooth**: `rc-service bluetooth status` shows the
      daemon running with `hci0` up (BCM4343A2 firmware loads at
      boot). Pairing: make a device discoverable, then
      `bluetoothctl scan on` + `bluetoothctl pair <mac>`.

## Wi-Fi on the device (post-flash)

### On-demand graphical apps (NOT baked — apk add when wanted)

Persistence carries anything you install across reflashes automatically
(hourly snapshot; run `cpz-save` right after installing to be safe).
Recommended light picks for the HDMI session:

```sh
apk add imv        # Wayland-native image viewer, a few MB
apk add lf         # terminal file manager, zero GUI cost
apk add epiphany   # the browser — Wayland-native, but WebKit:
                   # ~100-200 MiB with a page open on this 512 MB board,
                   # fine for light pages
```
All appear in the Super+d launcher. (In-session split panes: Tilix,
Ctrl+Shift+O/E — no extra apps needed.)

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
