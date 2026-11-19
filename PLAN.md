# CPZ-Alpine — Master Plan

## 1. Mission

Build an entirely new, extremely light operating system for the M5Stack
CardputerZero, based on **Alpine Linux (aarch64)**, with:

1. every hardware feature of the device working (verified by test),
2. an HDMI desktop that exists **only on demand** (nothing graphical at boot),
3. USB host + wired Ethernet + Wi-Fi (+ Bluetooth),
4. idle RAM and boot time far below the stock Raspberry Pi OS image.

The stock OS is a showcase image: it boots a full graphical target, a demo
application, plymouth, 128 MB reserved for the GPU, and a 32-bit `armhf`
package arch alongside `arm64`. We discard all of that and build the OS the
device actually deserves.

## 2. Non-goals

- **No systemd, no X11, no "app store", no desktop environment.** Wayland
  compositors only, started manually.
- **No replacement of VideoCore boot firmware.** `bootcode.bin`/`start4.elf`/
  `fixup4.dat` are closed blobs and the only boot path; we keep them.
- **No reuse of the stock demo layer.** APPLaunch, splash screens, graphical
  target — all dropped.
- **No suspend-to-RAM illusions.** BCM2837 cannot suspend; the power story is
  fast boot + blanking + runtime PM (see §8 R9).
- **No binary-only kernel modules.** Everything we run is mainline or
  M5Stack-published GPL source, built by us.

## 3. Architecture

```
power on
  └─ BCM2837 boot ROM
      └─ VideoCore firmware (closed, FAT32 boot partition)  ← keep as-is
          ├─ config.txt   (ours: gpu_mem/cma profiles, DTB selection)
          ├─ cmdline.txt  (ours: fbcon=map:0, console=tty1, nosplash)
          ├─ kernel8.img  (Phase A: M5's; Phase B/C: ours)
          └─ DTB         (M5 CM0-CardputerZero board data, harvested)
              └─ Linux (arm64)
                  └─ initramfs (mkinitfs: panel + vc4 modules, panel firmware)
                      └─ OpenRC (musl + BusyBox userland)
                          ├─ getty on tty1 → console on internal 320×170 LCD
                          ├─ networking: eth0 (udhcpc), wlan0 (wpa_supplicant)
                          ├─ dropbear (SSH), crond, syslog ring, triggerhappy
                          └─ [on demand only] seatd + sway session on HDMI
```

Default runtime state: a text console OS on the internal LCD, no compositor
processes, ~40–60 MB used, all radios and buses available. The HDMI output is
reserved for the on-demand desktop session (`docs/05-hdmi-on-demand.md`).

## 4. Phases, stages, gates

| Stage | Title | Outcome (acceptance gate) | Effort |
|---|---|---|---|
| **Phase I — Foundation** | | | |
| [00](stages/stage-00-tooling-and-backup.md) | Tooling & stock backup | Stock SD fully imaged + hashed; workbench ready | ~1 h |
| [01](stages/stage-01-hardware-discovery.md) | Hardware discovery & BSP harvest | Authoritative hardware map; `harvest/` bundle with DTB, panel firmware, Wi-Fi/BT firmware, keymap, kernel modules | 2–3 h |
| [02](stages/stage-02-alpine-base.md) | Alpine base install | Alpine sys-mode boots to getty via HDMI/serial console; apk works | 1–2 h |
| [03](stages/stage-03-boot-display-console.md) | Boot chain & LCD console | **Gate G1:** readable text console on the internal LCD at boot | 3–6 h |
| **Phase II — Full hardware** | | | |
| [04](stages/stage-04-keyboard.md) | Keyboard & input | All 46 keys incl. SYM layer correct on console | 1–2 h |
| [05](stages/stage-05-networking.md) | Networking | USB host, Ethernet DHCP, Wi-Fi WPA2 (+BT) all pass runbook | 2–4 h |
| [06](stages/stage-06-power-rtc-imu.md) | Power, RTC, IMU | Battery/thermal in shell prompt; RTC persists across power-off; IMU readable | 2–3 h |
| [07](stages/stage-07-audio-camera-ir-buses.md) | Audio, camera, IR, buses | **Gate G2:** every row of the support matrix verified | 4–8 h |
| **Phase III — Desktop** | | | |
| [08](stages/stage-08-hdmi-desktop.md) | HDMI desktop on demand | **Gate G3:** compositor starts in ≤10 s on command/hotplug, stops cleanly, never at boot | 4–6 h |
| **Phase IV — Ship** | | | |
| [09](stages/stage-09-optimize-harden.md) | Optimize & harden | Idle ≤60 MB w/ radios on; boot ≤12 s; image ≤1 GB | 2–4 h |
| [10](stages/stage-10-reproducible-build.md) | Reproducible builds | **Gate G4:** scripted clean build produces a bootable image twice | 6–10 h |

Total: roughly 28–49 focused hours — two to three weekends including
waiting-on-hardware time.

## 5. Kernel strategy (the biggest technical decision)

We never write kernel drivers; we assemble them. Three phases, advance only
when the criteria are met, fall back when they are not:

| Phase | Kernel | How | Criteria to use it | Risks |
|---|---|---|---|---|
| **A — graft** | M5's stock `kernel8.img` + its `/lib/modules` | copied from `harvest/` into the Alpine root (kernel modules don't care about musl vs glibc) | First boot to G1/G2 fast; guarantees panel/codec drivers exist exactly as M5 shipped them | No apk-managed kernel updates; version frozen at stock |
| **B — Alpine kernel** | Alpine `linux-rpi` (Raspberry Pi Foundation kernel tree, apk-managed) | graft only the harvested DTB/overlays + firmware files; kernel package stays upstream | every harvested driver module exists and probes (panel-mipi-dbi, tca8418, the USB-Ethernet chip, brcmfmac, bq27xxx, rtc-rx8130, bmi270, imx219, the audio machine driver…) | Any missing M5 patch breaks a peripheral — most likely audio |
| **C — custom kernel** | `linux-cpz` APKB: raspberrypi/linux + M5Stack's GPL patches, built via aports overlay | `packages/cpz/linux-cpz` (Stage 10) | triggered by Phase B gaps; gives us kernel updates *and* full hardware | requires M5Stack's published kernel source (GPL) |

Expected path: **A for Phase I–II** (it just works and proves the userland),
**B tried during Stage 09/10** with a per-peripheral probe checklist, **C
built only for the gaps B leaves** (the ES8389 audio machine driver is the
prime suspect, possibly also the panel DT bindings).

Rule of thumb used throughout: the DTB/overlays are *board data* — they can be
grafted onto any kernel version whose drivers understand the nodes. Firmware
blobs (panel init, Wi-Fi nvram, BT `.hcd`) are copied verbatim from the stock
image, which is the authoritative source for this board.

## 6. Budgets

### Memory map (512 MB total, console profile / desktop profile)

| Region | Console | Desktop | Notes |
|---|---|---|---|
| `gpu_mem` (VideoCore) | 32 MB | 96 MB | firmware-fixed at boot; cannot change at runtime |
| CMA (`cma=`) | 64 MB | 128 MB | vc4 KMS framebuffers (incl. 1080p HDMI when used) |
| Kernel + initramfs handoff | ~50 MB | ~50 MB | measured in S03/S09 |
| Userspace idle target | **≤ 60 MB** | ≤ 60 MB | OpenRC, getty, dropbear, wpa_supplicant, udhcpc, thd, syslog ring |
| Free for work | ~300 MB | ~200 MB | zram (128 MB) optional in S09 |

The whole reason HDMI desktop is "on demand": in console profile the desktop
runs on **llvmpipe** (CPU-rendered Wayland) which is fine for terminals on a
quad A53; the desktop profile (higher `gpu_mem`/CMA, reboot) enables vc4 GLES
and VideoCore H.264 decode. Both profiles are one script away — `docs/05` §3.

### Boot / storage / speed targets

| Metric | Target | Stretch |
|---|---|---|
| Power → login prompt on LCD | ≤ 12 s | ≤ 8 s |
| `cpz-desktop start` → usable HDMI session | ≤ 10 s | ≤ 6 s |
| Idle RSS with Wi-Fi+BT on | ≤ 60 MB | ≤ 45 MB |
| Rootfs image size | ≤ 1 GB | ≤ 600 MB |
| SD write durability | ext4 + fsck; ro-root option (S09) | — |

## 7. Decision log

- **D1 — Base:** Alpine Linux aarch64 (user decision). musl + BusyBox + OpenRC,
  apk for tools, ~100 MB base. The lightest base that remains a *maintained
  distro* rather than a one-off firmware.
- **D2 — Install mode:** sys mode on ext4 (traditional rootfs), not
  Alpine's diskless/run-from-RAM mode — we want a "real OS" with `apk upgrade`
  for userland; ro-root overlay is an S09 hardening option, not the default.
- **D3 — Init:** OpenRC; early KMS via mkinitfs; no systemd ever.
- **D4 — Kernel:** phases A/B/C above.
- **D5 — Console:** fbcon on the internal LCD (`fbcon=map:0`, `console=tty1`).
  HDMI never steals the console (`hdmi_force_hotplug` stays OFF) — it belongs
  to the on-demand desktop only.
- **D6 — Desktop:** Wayland-only: seatd (no logind) + sway + foot; labwc/cage
  as lighter fallbacks. No X11 stack at all.
- **D7 — Networking:** ifupdown-ng + busybox udhcpc + wpa_supplicant; wireless
  firmware harvested from the stock image (board-authoritative, incl. nvram).
- **D8 — Device manager:** eudev (needed for DRM hotplug events and USB
  automount), not mdev.
- **D9 — Timekeeping:** RX8130CE RTC + hwclock; busybox ntpd when network is
  up (RTC makes reboots exact regardless).
- **D10 — Hotkeys:** triggerhappy (`thd`) — tiny input-event daemon for
  power/shutdown keys, no heavyweight desktop daemons.
- **D11 — Console font:** Spleen 5×8 PSF → 64×21 characters on the 320×170
  LCD (the best readability/character-count tradeoff measured by the
  community; miniwi 4×8 → 80×21 exists if more columns ever matter).

## 8. Risk register

| # | Risk | Mitigation / fallback |
|---|---|---|
| R1 | ES8389 audio machine driver is an M5 patch, absent from mainline/Alpine kernel | Phase A kernel keeps audio working from day one; Phase C `linux-cpz` ports the patch; GPL source from M5Stack is the dependency — request early (S01) |
| R2 | mkinitfs doesn't include `cardputerzero,st7789v_lcd.bin` panel firmware | Verify initramfs contents; if missing, custom mkinitfs hook; final fallback: load panel modules post-pivot (console appears seconds later, still usable) |
| R3 | LCD blanks mid-boot when console font/keymap applies (race seen on stock) | Known workaround, translated to our OpenRC unit: blank+unblank `fb0` right after `setfont`/`loadkeys` (S03/S04) |
| R4 | Ethernet controller identity unknown (likely LAN9514-class USB chip) | S01 `lsusb` resolves it; kernel already carries all common USB-Ethernet drivers (smsc95xx, r8152, asix, cdc_ether, lan78xx) |
| R5 | Alpine `linux-rpi` lacks M5 DT bindings | DTB graft usually survives (board data); if not, stay on Phase A/B-hybrid; Phase C fully solves |
| R6 | Camera stack (libcamera) too heavy for 512 MB | Scoped as an on-demand CLI app (never a boot service); standard model only; Lite model unaffected |
| R7 | sway + mesa too heavy for desktop profile | zram optional; llvmpipe instead of vc4 GL; labwc or cage (lighter compositors) as swap-in alternatives |
| R8 | SD corruption on power loss (pocket device!) | fast clean shutdown via hotkey (thd), fsck on boot, optional ro-root overlay (S09) |
| R9 | No suspend-to-RAM on BCM2837 | Honest power strategy: fast boot (≤12 s), `consoleblank`, backlight off, Wi-Fi powersave, USB runtime PM, optional underclock (`arm_freq`) |
| R10 | Which USB-C port carries OTG data is undocumented | Determined empirically in S01; recorded in docs/01 |

## 9. Definition of done

- [ ] Every row in `docs/01-hardware-inventory.md` is **supported**, with the
      verifying test from `docs/06-testing.md` recorded.
- [ ] HDMI desktop: zero compositor processes at boot (assert `pgrep` clean);
      starts ≤10 s via command or hotplug; stops cleanly; LCD console
      unaffected throughout.
- [ ] USB host (mass storage + HID), wired Ethernet DHCP, Wi-Fi WPA2-PSK all
      pass the runbook; Bluetooth scans.
- [ ] Budgets met: idle ≤60 MB with radios on; boot ≤12 s; image ≤1 GB.
- [ ] Stage 10: two consecutive clean scripted builds produce a bootable image
      that passes the smoke runbook.

## 10. Repository layout (target)

```
cardputer-zero-alpine/
├── README.md
├── PLAN.md                  ← you are here
├── docs/                    ← design (done, evolves with findings)
├── stages/                  ← execution guides (done, one per stage)
├── harvest/                 ← from stock image; NEVER committed (gitignored)
├── rootfs-overlay/          ← files copied over the Alpine rootfs at build
├── build/                   ← image build scripts (created in S10)
├── packages/cpz/            ← custom APKBs: linux-cpz, cpz-* (S10)
└── images/                  ← built images + checksums (gitignored)
```
