# 03 — The Alpine approach

## 1. Why Alpine

| Property | Alpine | vs stock RPi OS |
|---|---|---|
| libc | musl (tiny, static-friendly) | glibc |
| Base userland | BusyBox | full GNU coreutils + systemd |
| Init | OpenRC | systemd (+ graphical.target) |
| Package manager | apk (fast, small repos) | apt/dpkg (+ armhf multilib) |
| Base image | ~100 MB | ~2 GB+ |
| Idle RAM | ~20–40 MB | ~200+ MB |
| Early userspace | mkinitfs | initramfs-tools + plymouth |

It is the lightest base that stays a *maintained distribution* — we keep
`apk upgrade` for userland security updates instead of hand-rolling
everything (that's the Buildroot route, deliberately not chosen).

Image: the **`alpine-rpi-<release>-aarch64.img.gz`** "raspberrypi" image
(current stable, e.g. v3.22 series — pin one release per build). It ships the
Raspberry Pi kernel (`linux-rpi`, the Raspberry Pi Foundation tree), VideoCore
firmware on the FAT boot partition, and DTBs for Pi 3-class boards.

## 2. Install mode: sys (traditional ext4 rootfs)

Alpine offers diskless (run-from-RAM), data, and sys modes. We use **sys
mode** on ext4: a real, updatable root filesystem. Alpine's default
run-from-RAM elegance doesn't fit a pocket computer that must survive
unclean power loss with mutable config — and `apk upgrade` semantics are
simplest against an ext4 root. SD-resilience is handled separately in S09
(fast clean shutdown, fsck, optional ro-root overlay).

Install path (Stage 02): boot the Alpine rpi image, run `setup-alpine`
(answers scripted in the stage file), then `setup-disk -m sys` following the
[Alpine Wiki classic install](https://wiki.alpinelinux.org/wiki/Raspberry_Pi)
for Pi-specific boot partition handling (FAT32 p1 keeps firmware/kernel/DTBs;
ext4 p2 is the root). Verify against the wiki for the pinned release — the
fine print of `setup-disk` on rpi images has changed between releases.

## 3. Kernel strategy recap (details in PLAN §5)

- **Phase A (bring-up):** M5's stock kernel + modules, Alpine userland.
  Kernel modules don't link against libc, so musl vs glibc is irrelevant —
  the graft is safe. Guarantees the panel/codec drivers behave exactly as
  shipped.
- **Phase B (apk-managed):** Alpine `linux-rpi` + harvested DTB/overlays/
  firmware. Advance only if every harvested driver exists and probes
  (checklist from `harvest/logs/lsmod.txt`).
- **Phase C (ours):** `linux-cpz` APKB = raspberrypi/linux + M5's GPL
  patches, built in our aports overlay (S10). Solves whatever B lacks.

## 4. Boot configuration targets (console profile)

Starting point is always the *stock* `config.txt`/`cmdline.txt` — we change
only what we understand, one variable at a time, with a working boot between
each change.

`config.txt` (FAT32 boot partition):

```ini
# --- CPZ-Alpine console profile (see docs/05 §3 for the desktop profile) ---
device_tree=bcm2710-rpi-cm0-cardputerzero.dtb   # exact DTB filename from harvest
disable_overscan=1
boot_delay=0
gpu_mem=32                                      # 320x170 panel needs almost nothing
# splash_screen=...   ← stock line REMOVED (no boot splash)
# hdmi_force_hotplug stays OFF: HDMI belongs to the on-demand desktop only
```

`cmdline.txt`:

```
console=tty1 fbcon=map:0 consoleblank=60 nosplash root=PARTUUID=<ours> rootfstype=ext4 rw cma=64M cfg80211.ieee80211_regdom=BG
```

- `fbcon=map:0` — console goes to `fb0` = internal LCD (per community
  testing of this board; `map:10` would try HDMI first — we explicitly do
  *not* want that).
- `consoleblank=60` — LCD blanks after 1 min idle (R9 power strategy).
- `cma=64M` — vc4 KMS framebuffers; raised to 128M in the desktop profile.
- During development: drop `quiet`, keep verbose logging until S09.

## 5. Early display: mkinitfs plan + known pitfalls

Alpine uses **mkinitfs** (not initramfs-tools). Target
`/etc/mkinitfs/mkinitfs.conf`:

```
features="base"
modules="spi_bcm2835 drm drm_kms_helper drm_mipi_dbi panel_mipi_dbi_m vc4 tca8418_keypad i2c_bcm2835"
```

> The module list (including the odd `panel_mipi_dbi_m`) mirrors the
> module set the stock image needs for early framebuffer output; exact names
> are validated against `harvest/logs/lsmod.txt` in Stage 03. Add
> `rtc-rx8130`/`bq27xxx` later only if we ever want them pre-pivot.

Pitfalls, with fallbacks:

1. **Panel firmware in the initramfs (R2).** `panel_mipi_dbi` requests
   `cardputerzero,st7789v_lcd.bin` at probe; mkinitfs should include it via
   its firmware scan. Verify:
   ```sh
   mkinitfs $(uname -r)   # or: mkinitfs -c /etc/mkinitfs/mkinitfs.conf
   gzip -dc /boot/initramfs-* | cpio -t | grep -Ei 'st7789|panel'
   ```
   If missing → custom mkinitfs hook; final fallback: let the panel load
   post-pivot from the real rootfs `/lib/firmware` (console appears a few
   seconds later — still a working device, just less polished).
2. **LCD blanks mid-boot when the font/keymap applies (R3).** Known race on
   this board (seen when stripping plymouth on the stock image). Fix baked
   into our console unit right after `setfont`/`loadkeys`:
   ```sh
   echo 1 > /sys/class/graphics/fb0/blank   # force a *known* blank state
   echo 0 > /sys/class/graphics/fb0/blank   # unblank — now the flag is honest
   ```
3. **DRM vs fbcon naming.** `fbcon=map:0` assumes the internal panel is
   fb0; confirm with `cat /sys/class/graphics/fb0/virtual_size` → `320,170`
   on first graft boot.

## 6. OpenRC service inventory (default boot)

| Service | Purpose | Runlevel |
|---|---|---|
| `udev` (eudev) | drm hotplug events, USB automount — D8 | sysinit |
| `hwclock` | RX8130CE RTC (D9) | boot |
| `seedrng` | entropy | boot |
| `networking` (ifupdown-ng) | eth0/wlan0 via `/etc/network/interfaces` | boot |
| `wpa_supplicant` | Wi-Fi auth | boot |
| `dropbear` | SSH (key-only) | default |
| `crond` (busybox) | scheduled scripts | default |
| `syslogd -C64` (busybox) | in-memory ring buffer, no SD writes | default |
| `local` | `/etc/local.d/console.start`: keymap + font + blank fix | default |
| `thd` (triggerhappy) | power/hotkey events | default |
| `seatd` | started ON DEMAND by cpz-desktop only | never auto |

Everything else that Alpine may enable by default gets pruned in S09 with
`rc-status --all` as the checklist.

## 7. Package manifest (userland)

**Base / console (S02–S06):** `doas dropbear wpa_supplicant iw ifupdown-ng
kbd eudev triggerhappy i2c-tools alsa-utils` — plus BusyBox applets already
in the base (crond, syslogd, udhcpc, ntpd, ash).

**Verify-at-install names** (Alpine splits/renames happen; check with
`apk search` before assuming): `triggerhappy`, `zram-init`, mesa subpackage
providing the `vc4` Gallium driver, libcamera rpi support.

**Desktop-only (S08, community repo):** `sway seatd foot mesa-dri-gallium
wl-clipboard grim font-dejavu` (+ `labwc` as the lighter fallback candidate).

**Camera/audio tools (S07, optional):** `libcamera libcamera-tools
v4l-utils`.

No compilers, no Python, no Perl, no databases in the base image —
development happens on the build host (S10), not on the device.

## 8. Memory budget (summary — full table in PLAN §6)

Console profile: `gpu_mem=32` + `cma=64M` + kernel ≈50 MB leaves **~360 MB**
of which userland must hold **≤ 60 MB idle** (getty, OpenRC, dropbear, wpa,
udhcpc, thd, syslog ring). Desktop profile: `gpu_mem=96` + `cma=128M` leaves
~240 MB — sway + foot + llvmpipe/vc4 measured to fit in S08, zram optional.
