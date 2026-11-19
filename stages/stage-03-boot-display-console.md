# Stage 03 — Boot chain & LCD console

> Phase I · depends on: Stages 01 + 02 · effort: 3–6 h · status: **not started**
> **This is Gate G1: the moment the CPZ becomes a pocket computer.**

## Goal

Graft the harvested M5 boot chain (Phase A: stock kernel + modules + DTB +
panel firmware) onto the Alpine root, and boot to a readable text console on
the internal 320×170 LCD. No splash, no plymouth, no desktop — just Linux on
the little screen, with `fbcon=map:0`.

## Steps

### 1. Graft the Phase-A kernel

```sh
# on the build host, from harvest/:
scp -r harvest/boot/kernel8.img root@cpz:/boot/firmware/          # M5 kernel
scp -r harvest/modules/* root@cpz:/lib/modules/                  # its module tree
scp harvest/dtb/*.dtb harvest/dtb/*.dtbo root@cpz:/boot/firmware/ # board DT + overlays
scp -r harvest/firmware/brcm root@cpz:/lib/firmware/              # wireless blobs
# panel init blob — exact path comes from the DT's panel node (Stage 01 notes):
scp 'harvest/firmware/*st7789*' root@cpz:/lib/firmware/
```

- The VideoCore firmware files (`start4.elf`, `fixup4.dat`, `bootcode.bin`)
  already on Alpine's FAT partition are fine — same Pi 3-class platform.
  Only swap them if something inexplicable happens.

### 2. `config.txt` + `cmdline.txt` (one change at a time!)

Work from Alpine's stock files, applying **only** the diffs from
[docs/03 §4](../docs/03-alpine-approach.md), in this order, rebooting
between each:

1. `device_tree=` ← the harvested active-DTB filename (or the stock
   `dtoverlay=` lines, whichever mechanism Stage 01 recorded)
2. `cmdline.txt`: add `fbcon=map:0 console=tty1 consoleblank=60`
3. `gpu_mem=32` (from whatever Alpine ships), remove any splash lines
4. `cma=64M`

> Why incremental: if step N breaks the boot, the culprit is a one-line
> diff, and serial console (`console=ttyAMA0,115200` — add it *first*
> actually, it's free) tells you why.

### 3. mkinitfs for early display

```sh
# /etc/mkinitfs/mkinitfs.conf:
#   features="base"
#   modules="spi_bcm2835 drm drm_kms_helper drm_mipi_dbi panel_mipi_dbi_m vc4 i2c_bcm2835"
# (module names cross-checked against harvest/logs/lsmod.txt)
doas mkinitfs $(ls /lib/modules)
doas gzip -dc /boot/initramfs-* | cpio -t | grep -Ei 'st7789|panel'   # R2 check!
```

- [ ] If the panel blob is missing from the initramfs: write the mkinitfs
      hook (add `/lib/firmware/cardputerzero,st7789v_lcd.bin` via the
      firmware mechanism), rebuild, re-verify.
- [ ] If it *still* won't come up early: drop `panel_mipi_dbi` from the
      initramfs modules — the panel then initializes after rootfs pivot,
      console appears a few seconds later. Working-but-late beats
      broken-but-elegant. Log it in PLAN R2.

### 4. Boot and verify the console

```sh
cat /sys/class/graphics/fb0/virtual_size    # → 320,170
dmesg | grep -iE 'drm|panel|vc4'            # panel bound, vc4 initialized
```

- [ ] Text appears on the LCD at boot *and stays* through OpenRC to getty.
- [ ] If the screen blanks mid-boot when fonts apply — that's R3: add the
      blank/unblank workaround now (see Step 5) and stop worrying.

### 5. Console font: 64×21 characters

```sh
doas apk add kbd
# obtain a PSF/PSFU build of Spleen 5×8 (convert from its BDF/PSF sources);
# place at /usr/share/kbd/consolefonts/cpz-spleen-5x8.psfu
setfont cpz-spleen-5x8                       # 64 cols × 21 rows on 320×170
```

Persist via `/etc/local.d/console.start` (owner root:root, +x):

```sh
#!/bin/sh
setfont cpz-spleen-5x8
echo 1 > /sys/class/graphics/fb0/blank     # R3 race fix: force a known state
echo 0 > /sys/class/graphics/fb0/blank     # ...then unblank honestly
```

```sh
doas rc-update add local default
```

### 6. Record G1 evidence

- [ ] Photo of the console on the LCD (docs/06 practice: claims need proof)
- [ ] `free -m`, boot stopwatch, `dmesg` clean → into the S09 "before" table
- [ ] PLAN §5 Phase A: marked working; note anything that did *not* probe

## Files produced

Working LCD console · `/etc/mkinitfs/mkinitfs.conf` ·
`/etc/local.d/console.start` · graft notes for Stage 10's build scripts

## Acceptance gate (G1)

- [ ] Cold boot → readable 64×21 console on internal LCD, no splash ever
- [ ] `fbcon=map:0` confirmed: HDMI unplugged/plugged does not move the console
- [ ] dmesg: panel + vc4 probed clean; no oops/regression in `logs/`
- [ ] boot time recorded (target ≤ 12 s; stretch 8 s)
- [ ] Phase-A kernel is *not* apk-managed — written into the Stage 10 TODO
      (the graft must be automated or Phase B/C must land)

## Risks & fallbacks

| Risk | Fallback |
|---|---|
| DTB selection mechanism differs (custom dtb vs overlay stack) | mirror the stock `config.txt` mechanism exactly — Stage 01 recorded it |
| mkinitfs won't carry the panel blob (R2) | hook → post-pivot panel init (console late, alive) |
| fbcon lands on HDMI instead of LCD (`map:0` wrong for our DT order) | `fbcon=map:10`; verify with `cat /sys/class/graphics/fb*/virtual_size` |
| Stock kernel conflicts with Alpine's `linux-rpi` in apk world | Phase A boots from `config.txt`'s `kernel=`; keep both installed, they don't collide (different `/lib/modules` names) — document in Stage 10 |
