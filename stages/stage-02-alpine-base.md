# Stage 02 — Alpine base install

> Phase I · depends on: Stage 00 (lab SD card) · effort: 1–2 h · status: **not started**

## Goal

Alpine Linux (aarch64, sys mode) boots on the CardputerZero to a getty,
reachable via HDMI or serial console. *Not* the LCD yet — no M5 DTB is
grafted so the panel stays dark (expected); we just need a clean Alpine
with working apk, networking services, and a baseline of measurements.

## Steps

### 1. Fetch & flash

```sh
# pin the release you'll keep for the whole project (e.g. current stable v3.22)
wget "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-rpi-<ver>-aarch64.img.gz"
gunzip alpine-rpi-<ver>-aarch64.img.gz
sha256sum alpine-rpi-<ver>-aarch64.img   # verify against the .sha256 file

# flash to the LAB card — /dev/sdX is the LAB card, not the stock backup!
lsblk                                    # triple-check SIZE
sudo dd if=alpine-rpi-<ver>-aarch64.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

### 2. First boot & console access

- [ ] Lab card into the CPZ, boot — console via **HDMI** (stock Alpine
      config drives HDMI fine) or the serial adapter.
- [ ] Login `root` (no password on first boot). You are in Alpine's
      diskless boot; we convert to sys mode now.

### 3. `setup-alpine` — scripted answers

```sh
setup-alpine
# answers:
#   keyboard: us (CPZ keymap arrives in Stage 04)
#   hostname: cpz
#   interface: try eth0/dhcp (usb-eth may already work — bonus; else lo for now)
#   root password: set one now (locking down in S09)
#   timezone: Europe/Sofia
#   proxy: none
#   ssh: dropbear
#   ntp: busybox ntpd
#   apk repos: enable main + community, pick a mirror
#   user: cpz (shell ash, added to wheel for doas later)
```

### 4. Convert to sys mode (traditional ext4 root)

Follow the [Alpine Wiki classic Raspberry Pi install](https://wiki.alpinelinux.org/wiki/Raspberry_Pi)
for the release you pinned — the flow is `setup-disk -m sys /dev/mmcblk0`,
which creates the ext4 root partition and relocates boot files onto the
FAT32 partition the firmware needs. Verify against the wiki: the exact
`setup-disk` incantation on rpi images has release-specific fine print.

- [ ] After `setup-disk` + reboot: `mount | grep 'on / '` shows ext4 on
      mmcblk0p2 (or equivalent) — **not** tmpfs. Alpine now persists.

### 5. Device manager + baseline services

```sh
setup-devd udev          # eudev: drm hotplug + usb automount (D8)
doas apk add doas kbd dropbear eudev ifupdown-ng wpa_supplicant iw
doas rc-update add dropbear
doas rc-update add networking
doas rc-update add seedrng boot
# prune anything setup-alpine added that we don't want (audit: rc-status --all)
```

- [ ] `doas.conf`: `permit persist :wheel` (root-less admin from now on)

### 6. Record the baseline (before any CPZ grafting)

```sh
free -m > /root/baseline-ram.txt
# boot time: note dmesg last timestamp + stopwatch to prompt (docs/06 §5)
dmesg > /root/baseline-dmesg.txt
cp /etc/apk/world /root/baseline-apk-world.txt
```

These numbers are the "before" column for S09's optimization table.

### 7. Optional early win: USB-Ethernet

If `smsc95xx` (or the harvested chip's driver) is a module in the Alpine
kernel: `modprobe <driver>` → if `eth0` appears, wire it up per
[docs/04 §2](../docs/04-networking.md) and enjoy SSH networking from now
on. If not — serial console carries us to Stage 03/05. No time spent
debugging here: the graft comes first.

## Files produced

Booting LAB SD · `/root/baseline-*` · `apk world` snapshot

## Acceptance gate

- [ ] Alpine boots to getty via HDMI/serial, persists across reboot (sys mode)
- [ ] `apk add` works (network via host-side or USB-eth; else transfer apks)
- [ ] eudev enabled; dropbear + doas usable
- [ ] Baseline RAM/boot/dmesg recorded
- [ ] LCD dark is understood and expected (Stage 03 fixes it)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| `setup-disk` boot-partition handling differs per release | wiki walkthrough for the *pinned* release; worst case: manual two-partition layout, copy Alpine's FAT boot files, edit `cmdline.txt` root= |
| No console at all (HDMI dark too) | serial adapter on the 14-pin UART — configure `console=ttyAMA0,115200` in cmdline for the lab card |
| eth0 unknown at this stage | proceed serial-only; networking is Stage 05's problem, not Stage 02's |
