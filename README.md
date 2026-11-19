# cardputer-zero-alpine-linux

An extremely light, purpose-built **Alpine Linux** operating system for the
**M5Stack CardputerZero** (Raspberry Pi CM0 / RP3A0, Broadcom BCM2837).

**Status: v0.12.0 — hardware-verified.** Boot to LCD login with the
full keyboard (keycap-correct SYM layer), battery + SoC temperature in the
prompt, Wi-Fi and Ethernet, USB-C serial console, SSH, and a persistence
partition that survives reflashes.

| Subsystem | State | Notes |
|---|---|---|
| Boot → LCD login | ✅ | 320×170 fbtft panel is the console (`fbcon=map:1`) |
| Keyboard (46-key + SYM/FN) | ✅ | keymap rebuilt from measured keycap legends — see `rootfs-overlay/usr/share/keymaps/cpz-sym-keymap.map` |
| Battery gauge (BQ27220) | ✅ | stock module was stale; rebuilt from M5's vendor source against exact distro headers |
| Keyboard LEDs | ✅ | expander plays a host-wait marquee until the `READY` handshake (reg `0xB0`) — one `i2cset` at boot |
| Wi-Fi (BCM43439) | ✅ | soft rfkill block lifted at boot; credentials baked at build time |
| Ethernet (SR9900A) | ✅ v0.12.2 | mainline r8152 ID patch, dwc2 host mode — field-verified: DHCP lease + ~2 ms RTT traffic |
| USB-C serial console | ⚠️ retired | dwc2 is host-only for ethernet + USB-A (otg dead-end logged in config.txt); Wi-Fi/Ethernet SSH is the remote path |
| SSH (dropbear) | ✅ | over Wi-Fi |
| Persistence across reflashes | ✅ | `CPZDATA` partition + hourly snapshots + boot restore |
| HDMI desktop (on demand) | ✅ v0.14.0 | `cpz-desktop start` → sway+foot on HDMI in ~5 s, ~57 MiB resident; nothing graphical at boot; hotplug consent via udev (`ask` mode) |
| Bluetooth, camera func, IR func | ⏳ | controller verified; capture + remote tests pending |

## Build

Docker-based and re-runnable; every input is pinned by hash
([build/INPUTS.md](build/INPUTS.md)):

```sh
sh build/20-rootfs.sh     # arm64 container: Alpine rootfs + overlay graft
sh build/30-image.sh      # partition, assemble, VERIFY (must end clean)
```

Requires Docker with `binfmt` for arm64 emulation. The verification pass
(`build/verification-report.txt`) must end **`verification clean`** — every
`FAIL:` line is a blocker.

## Flash (preserves your data)

```sh
sudo ./build/flash-cpz.sh /dev/sdX [image.img.gz]
```

Writes the image, then re-creates the **CPZDATA** partition at a fixed
offset and formats it only if missing. On the device, an hourly cron
snapshot (`cpz-save`) keeps `/root`, `/home/cpz`, dropbear keys, Wi-Fi
config and the package list in `/cfg`; every boot restores them
(`cpz-restore.start`). Raw `dd` also works but drops persistence for
that flash.

## Debugging aids shipped in the image

- `cpzdiag` — one-word field diagnostics; report lands on the FAT boot
  partition, readable from any desktop
- USB-C serial login (see above) and `dropbear` for SSH
- `/etc/local.d/*.start` scripts document their own fix history,
  including every dead end tried before the real fix

## Architecture (Phase A)

Stock M5 kernel `6.18.33+rpt-rpi-v8` + M5 out-of-tree modules + boot
firmware, grafted onto a minimal Alpine (musl/BusyBox/OpenRC) userland.
The kernel is bit-exact stock; where a driver was stale or missing
(battery gauge, Ethernet), the fix is an out-of-tree rebuild against
the exact matching distro headers — never a kernel fork.

Read in order: [PLAN.md](PLAN.md) (master plan) →
[docs/01-hardware-inventory.md](docs/01-hardware-inventory.md) →
[build/INPUTS.md](build/INPUTS.md) →
[docs/FLASH-AND-TEST.md](docs/FLASH-AND-TEST.md).

## Device summary

- **SoC:** Broadcom BCM2837 — 4× Cortex-A53 @ 1 GHz (Raspberry Pi CM0, RP3A0 SiP)
- **RAM:** 512 MB LPDDR2 — *the hard constraint everything is designed around*
- **Display:** 1.9″ ST7789V3 SPI LCD (320×170), HDMI out up to 1080p
- **Keyboard:** 46-key matrix on a TCA8418 I2C keypad controller
- **Networking:** 2.4 GHz Wi-Fi (BCM43439), BT 4.2/BLE, 10/100 Ethernet
  (SR9900A via the GL852G USB hub), USB 2.0
- **Peripherals:** IMX219 camera, ES8389 audio, BMI270+BMM150 IMU,
  RX8130CE RTC, BQ27220 fuel gauge, IR TX/RX, Grove HY2.0-4P,
  2.54 mm 14-pin expansion bus
- **Boot chain:** standard Raspberry Pi — closed VideoCore firmware on a
  FAT32 partition loads `kernel8.img` + DTB; everything above the kernel
  is ours.

512 MB of RAM means the desktop must be opt-in (PLAN §6/§8); the BCM2837
has no suspend-to-RAM, so power management is fast boot + blanking +
runtime PM.

## Sources

- [M5Stack CardputerZero product docs](https://docs.m5stack.com/en/CardputerZero)
- [M5Stack CardputerZero image guide](https://docs.m5stack.com/en/compute/cardputerzero/image)
- ["Taming the CardputerZero" — M. Birth](https://blog.mbirth.uk/2026/11/11/taming-the-cardputerzero.html)
- [It's FOSS: CardputerZero crowdfunding coverage + specs](https://itsfoss.com/news/cardputerzero-crowdfunding/)
- [Alpine Wiki: Raspberry Pi](https://wiki.alpinelinux.org/wiki/Raspberry_Pi)
- [Raspberry Pi Compute Module 0](https://www.raspberrypi.com/products/compute-module-zero/)
- [r8152: add vendor/device ID for CoreChips SR9900 (lore)](https://lore.kernel.org/all/20260613090154.1975753-1-zjzhao@edatec.cn/t/#u#1)

## License

GPL-2.0-or-later for the kernel/driver material (kernel headers, M5
vendor sources); the rest of the build system is yours to use. Vendor
sources retain their upstream licenses (`vendor/*/COPYING`).