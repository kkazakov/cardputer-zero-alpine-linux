# 02 — Stock OS analysis & BSP harvest

## 1. What the CardputerZero ships with

**Not a bespoke OS.** The stock image is **Raspberry Pi OS (Debian, arm64)
plus an M5Stack demo layer on top**, structured to showcase the hardware:

| Stock behavior | Evidence (stock image / community teardown) | Our verdict |
|---|---|---|
| Boots to `graphical.target` — full X11/Wayland session even with no HDMI attached | `systemctl set-default` needed to escape it | **discard** — we boot to multi-user/text |
| `APPLaunch.service` (user unit) auto-starts the demo/test app every boot | `systemctl --user disable APPLaunch.service` | **discard** |
| `fb_load.service` redraws a splash to the framebuffer during boot | systemd unit on stock | **discard** |
| `plymouth` boot beautifier | stock package; its removal breaks early display until DRM modules enter initramfs | **discard** (keep the lesson: panel modules must be in *our* initramfs, R2/R3) |
| `fbcon=map:off` in `cmdline.txt` hides the text console | stock cmdline | **discard** — we want `fbcon=map:0` (console on internal LCD) |
| `gpu_mem=128` — a quarter of RAM reserved for the GPU, for a 320×170 SPI panel | stock `config.txt` | **discard** — 32 MB console / 96 MB desktop profile |
| `armhf` (32-bit) arch enabled alongside arm64 — doubled package lists | `dpkg --remove-architecture armhf` needed | **discard** — pure aarch64 |
| Custom keymap only loaded by the demo app, not the system (`/etc/default/keyboard` is not configured) | blue SYM symbols dead after disabling demo | **fix properly** — load the keymap at the system level (S04) |
| No suspend/resume support on this SoC | community reports | **design around it** (R9) |

The on-screen "app store" and OpenClaw demos are userland on top of this —
irrelevant to a light OS, dropped wholesale.

Key sources: [M. Birth, "Taming the CardputerZero"](https://blog.mbirth.uk/2026/11/11/taming-the-cardputerzero.html),
[M5Stack image guide](https://docs.m5stack.com/en/compute/cardputerzero/image),
[M5Stack product docs](https://docs.m5stack.com/en/CardputerZero).

## 2. What we keep: the BSP harvest

We cannot write board support from scratch (panel init, board nvram, keymap
matrix), and we must not guess it. Everything board-specific is *harvested*
from the stock image once, then treated as source-of-truth artifacts:

### From the stock OS (running) — Stage 01

- **Kernel + modules (Phase A):** `/boot/firmware/kernel8.img` and the whole
  `/lib/modules/$(uname -r)/` tree.
- **Board DTB + overlays:** the *active* DTB (`cat /proc/device-tree/model`
  tells you which) and every overlay referenced by stock `config.txt`
  (`dtoverlay=…`). Decompiled source goes into `harvest/dtb/` too.
- **Panel firmware:** `cardputerzero,st7789v_lcd.bin` (the DRM
  `panel-mipi-dbi` init-sequence blob) → `/lib/firmware/` on our rootfs.
- **Wireless firmware:** the entire `/lib/firmware/brcm/` directory —
  `brcmfmac4343x-sdio.bin` + the **board nvram `.txt`** + BT `.hcd`.
  The nvram is board-specific: never substitute a generic download.
- **Keyboard console keymap:** `/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map`.
- **Kernel config:** `zcat /proc/config.gz` → `harvest/stock-kernel.config`
  (tells us exactly which drivers M5 enabled — the Phase B/C checklist).
- **Diagnostics:** `lsmod`, `dmesg`, `lsusb`, `/proc/bus/input/devices`,
  `/proc/asound/cards`, `iw list`, `v4l2-ctl --list-devices`,
  `/sys/class/power_supply/*` dumps → resolve every TBD in docs/01.
- **GPL kernel source pointer:** find M5Stack's kernel tree (their GitHub org)
  — legally required to be offered for the GPL kernel with their patches;
  request from support if not published. Needed for Phase C (`linux-cpz`).

### From the stock SD card (offline) — Stage 00/01

- Full `dd` backup of the entire card (our escape hatch — anything we break,
  the stock OS can be restored bit-exact).
- The FAT32 boot partition contents (VideoCore firmware, config.txt,
  cmdline.txt as *reference*, all DTBs/overlays).

### Keep vs drop summary

| Keep (harvest) | Drop (never copied) |
|---|---|
| kernel8.img + modules (Phase A) | the whole Debian/RPi OS userland |
| DTB + overlays | APPLaunch demo, app store, OpenClaw demos |
| `cardputerzero,st7789v_lcd.bin` | plymouth, splash bins, fb_load |
| `/lib/firmware/brcm/` | systemd units, graphical target |
| TCA8418 keymap `.map` | 128 MB gpu_mem config, armhf arch |
| stock kernel `.config`, lsmod/dmesg dumps | anything we can't explain in one line |

## 3. The harvest script (run once on the stock OS over SSH)

```sh
# as root on the STOCK device, with a USB stick or scp target available
mkdir -p /tmp/harvest/{boot,dtb,firmware,keymaps,modules,logs}

cp -a /boot/firmware/* /tmp/harvest/boot/                    # kernel, DTBs, config, firmware
cp -a /lib/modules/$(uname -r) /tmp/harvest/modules/          # Phase A drivers
cp -a /lib/firmware/brcm /tmp/harvest/firmware/              # wifi+bt blobs incl. nvram
cp -a /usr/share/keymaps/tca8418_keypad_m5stack_keymap.map /tmp/harvest/keymaps/
find /lib/firmware -name '*st7789*' -o -name '*cardputerzero*' | \
    xargs -r -I{} cp -a {} /tmp/harvest/firmware/             # panel init blob

zcat /proc/config.gz > /tmp/harvest/logs/kernel.config
uname -a                > /tmp/harvest/logs/uname.txt
lsmod                   > /tmp/harvest/logs/lsmod.txt
dmesg                   > /tmp/harvest/logs/dmesg.txt
lsusb -v                > /tmp/harvest/logs/lsusb.txt 2>&1
cat /proc/bus/input/devices > /tmp/harvest/logs/input.txt
cat /proc/asound/cards  > /tmp/harvest/logs/asound.txt
v4l2-ctl --list-devices > /tmp/harvest/logs/v4l2.txt 2>&1
iw list                 > /tmp/harvest/logs/iw.txt
hciconfig -a            > /tmp/harvest/logs/hci.txt 2>&1
find /sys/class/power_supply -type f -maxdepth 2 -exec \
    sh -c 'echo "$1: $(cat $1 2>/dev/null)"' _ {} \; > /tmp/harvest/logs/power.txt
cat /proc/device-tree/model > /tmp/harvest/logs/model.txt
systemctl cat APPLaunch.service fb_load.service > /tmp/harvest/logs/units.txt

# decompile the ACTIVE device tree
dtc -I dtb -O dts -o /tmp/harvest/dtb/active.dts \
    "$(find /boot/firmware -name '*.dtb' | xargs grep -ls "$(cat /proc/device-tree/model)" | head -1)"

# bundle + checksum
tar -C /tmp -czf cpz-harvest-$(date +%F).tar.gz harvest/
sha256sum cpz-harvest-$(date +%F).tar.gz > cpz-harvest-$(date +%F).sha256
```

Copy the tarball off the device (scp/USB), extract into
`/home/wasp/projects/cardputer-zero-alpine/harvest/` on the build host, and
commit only the *interpretation* (docs/01 statuses, config targets) — the
`harvest/` directory itself stays gitignored.
