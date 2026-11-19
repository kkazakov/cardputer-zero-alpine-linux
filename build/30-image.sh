#!/bin/sh
# build/30-image.sh — flashable image assembly.
#
# Runs INSIDE a privileged builder container (needs losetup/mount/mkfs):
#   /work  — cpz-work volume  (rootfs.tar, scratch)
#   /repo  — bind mount of the cardputer-zero-alpine checkout
# Produces:
#   /repo/images/cpz-alpine-0.1.0.img.gz + .sha256
#   /repo/build/verification-report.txt
set -eu

REPO=/repo
WORK=/work
OUT=$REPO/images
VER=0.13.0
IMG=$WORK/cpz-alpine-$VER.img
DISK_ID=10c0ffee

BOOT_START=16384          # sectors — 8 MiB gap, matches stock layout
BOOT_SIZE=524288          # 256 MiB FAT32
ROOT_SIZE=3145728          # 1536 MiB ext4
ROOT_START=$((BOOT_START + BOOT_SIZE))
TOTAL_SECTORS=$((ROOT_START + ROOT_SIZE))

mkdir -p "$OUT" "$WORK/fat-staging" /mnt/rootfs /mnt/boot

# --- loop hygiene: containers have no udev; explicit losetup + mknod ---
# detach any stale loops attached to our build files (a crashed previous
# run leaves them behind; snapd loops are not ours — never touched)
cleanup() {
    umount /mnt/boot /mnt/rootfs 2>/dev/null || true
    for f in "$IMG" $WORK/p1-fat.img $WORK/p2-root.img; do
        for L in $(losetup -j "$f" -O NAME 2>/dev/null | tail -n +2); do
            losetup -d "$L" 2>/dev/null || true
        done
    done
}
trap cleanup EXIT INT TERM
for f in "$IMG" $WORK/p1-fat.img $WORK/p2-root.img; do
    [ -f "$f" ] || continue
    for L in $(losetup -j "$f" -O NAME 2>/dev/null | tail -n +2); do
        echo "== detaching stale loop $L on $f =="
        losetup -d "$L" 2>/dev/null || true
    done
done

loop_mount() {  # loop_mount <file> <mountpoint>
    LO=$(losetup -f --show "$1")
    BASE=$(basename "$LO")
    [ -e "/dev/$BASE" ] || mknod "/dev/$BASE" b $(cat "/sys/class/block/$BASE/dev" | tr : ' ')
    mount "/dev/$BASE" "$2"
    LO_ACTIVE="$LO"
}

echo "== partition table (disk id 0x$DISK_ID) =="
truncate -s $((TOTAL_SECTORS * 512)) "$IMG"
sfdisk "$IMG" <<EOF
label: dos
label-id: 0x$DISK_ID
unit: sectors

start=$BOOT_START, size=$BOOT_SIZE, type=0c
start=$ROOT_START, type=83
EOF

echo "== carve partition images =="
dd if="$IMG" of=$WORK/p1-fat.img bs=512 skip=$BOOT_START count=$BOOT_SIZE status=none
dd if="$IMG" of=$WORK/p2-root.img bs=512 skip=$ROOT_START count=$ROOT_SIZE status=none

echo "== FAT boot partition (stock tree + our config) =="
rm -rf $WORK/fat-staging; mkdir -p $WORK/fat-staging
cp -a $REPO/harvest/boot/. $WORK/fat-staging/
# drop files this board can never use (2712 = Pi 5-class; u-boot = removed
# from our boot chain; stock Debian initramfs replaced by nothing in v0.1)
rm -f $WORK/fat-staging/u-boot.bin \
      $WORK/fat-staging/kernel_2712.img \
      $WORK/fat-staging/initramfs8 \
      $WORK/fat-staging/initramfs_2712 \
      $WORK/fat-staging/bcm2712-*.dtb \
      $WORK/fat-staging/bcm2712d0-*.dtb
# our boot configuration
cp $REPO/build/boot-config/config.txt $WORK/fat-staging/config.txt
cp $REPO/build/boot-config/cmdline.txt $WORK/fat-staging/cmdline.txt

mkfs.vfat -n CPZBOOT $WORK/p1-fat.img >/dev/null
mcopy -s -i $WORK/p1-fat.img $WORK/fat-staging/* ::/

echo "== ext4 root partition (from rootfs.tar) =="
mkfs.ext4 -q -F -L cpz-root $WORK/p2-root.img
loop_mount $WORK/p2-root.img /mnt/rootfs
tar -xf $WORK/rootfs.tar -C /mnt/rootfs
# docker bind mounts shadow these in the build container; write them here
cp $REPO/rootfs-overlay/etc/hostname /mnt/rootfs/etc/hostname
cp $REPO/rootfs-overlay/etc/hosts /mnt/rootfs/etc/hosts
printf 'nameserver 1.1.1.1\n' > /mnt/rootfs/etc/resolv.conf
# Wi-Fi credentials injection (v0.10): build/wifi-secret/ is NOT part of
# the repo — it holds this user's wpa_supplicant.conf + interfaces, fetched
# from the device. When present, every built image carries them, so
# reflashes never lose the network config again.
if [ -f $REPO/build/wifi-secret/wpa_supplicant.conf ]; then
    cp $REPO/build/wifi-secret/wpa_supplicant.conf \
       /mnt/rootfs/etc/wpa_supplicant/wpa_supplicant.conf
    cp $REPO/build/wifi-secret/interfaces \
       /mnt/rootfs/etc/network/interfaces
    echo "== wifi credentials injected (build/wifi-secret) =="
else
    echo "== no build/wifi-secret/ — shipping template wifi config =="
fi
# docker bind-mount point captured as an empty dir — remove it
rm -rf /mnt/rootfs/work
ROOT_USED=$(du -sm /mnt/rootfs | cut -f1)
umount /mnt/rootfs
losetup -d "$LO_ACTIVE"
echo "rootfs content: ${ROOT_USED} MiB (of $((ROOT_SIZE / 2048)) MiB)"
e2fsck -f -y $WORK/p2-root.img >/dev/null

echo "== write partitions back into the image =="
dd if=$WORK/p1-fat.img of="$IMG" bs=512 seek=$BOOT_START conv=notrunc status=none
dd if=$WORK/p2-root.img of="$IMG" bs=512 seek=$ROOT_START conv=notrunc status=none

echo "== verification pass =="
LO=$(losetup -f --show -P "$IMG")
BASE=$(basename "$LO")
[ -e "/dev/$BASE" ] || mknod "/dev/$BASE" b $(cat "/sys/class/block/$BASE/dev" | tr : ' ')
for P in $(ls /sys/class/block | grep "^${BASE}p"); do
    [ -e "/dev/$P" ] || mknod "/dev/$P" b $(cat "/sys/class/block/$P/dev" | tr : ' ')
done
mount -o ro "/dev/${BASE}p1" /mnt/boot
mount -o ro "/dev/${BASE}p2" /mnt/rootfs
KVER=$(ls /mnt/rootfs/lib/modules/ | grep 'rpi-v8' | head -1)

{
    echo "CPZ-Alpine $VER build verification — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "== boot partition =="
    ls -la /mnt/boot/ | head -50
    echo "--- config.txt (ours):"
    grep -E "^(gpu_mem|dtoverlay|dtparam|enable_uart|auto_initramfs)" /mnt/boot/config.txt
    if grep -Eq '^[[:space:]]*kernel[[:space:]]*=' /mnt/boot/config.txt; then
        echo "FAIL: kernel= override present"
    else
        echo "OK: no kernel override (direct kernel8.img boot)"
    fi
    echo "--- cmdline.txt (ours):"
    cat /mnt/boot/cmdline.txt
    grep -q "root=PARTUUID=$DISK_ID-02" /mnt/boot/cmdline.txt \
        && echo "OK: root PARTUUID matches disk id" || echo "FAIL: PARTUUID mismatch"
    # v0.1 shipped fbcon=map:0 and the panel never got the console (it is
    # fb1; the VideoCore firmware owns fb0). Field-fixed in v0.2.
    grep -q 'fbcon=map:1' /mnt/boot/cmdline.txt \
        && echo "OK: fbcon=map:1 (console on the fbtft panel)" \
        || echo "FAIL: fbcon map is not 1 — panel will stay dark"
    grep -qw 'rw' /mnt/boot/cmdline.txt \
        && echo "OK: root mounted rw" || echo "FAIL: no rw in cmdline"
    echo "--- kernel + DTB + overlays:"
    for f in kernel8.img start.elf fixup.dat bcm2710-rpi-cm0.dtb \
             overlays/cardputerzero-overlay.dtbo overlays/bq27220.dtbo \
             overlays/st7789v_m5stack.dtbo overlays/tca8418_m5stack.dtbo; do
        [ -s "/mnt/boot/$f" ] && echo "OK: $f" || echo "FAIL: $f missing"
    done
    # v0.5: rebuilt gauge driver. The stock image's compiled bq27xxx lacks
    # BQ27220 support (M5's vendor source has it; their .ko predates it) and
    # the stock overlay declared ti,bq27210 — wrong register map, every
    # read failed with -121 (EREMOTEIO).
    grep -aq "ti,bq27220" /mnt/boot/overlays/bq27220.dtbo \
        && echo "OK: gauge overlay declares ti,bq27220" \
        || echo "FAIL: gauge overlay still declares wrong compatible"
    KMOD=/mnt/rootfs/lib/modules/$KVER
    grep -aq "ti,bq27220" $KMOD/extra/bq27xxx_battery_i2c.ko \
        && echo "OK: gauge driver supports BQ27220" \
        || echo "FAIL: gauge driver lacks BQ27220"
    grep -aq "6.18.33+rpt-rpi-v8 SMP preempt mod_unload modversions aarch64" \
        $KMOD/extra/bq27xxx_battery_i2c.ko \
        && echo "OK: rebuilt gauge driver vermagic matches kernel" \
        || echo "FAIL: gauge driver vermagic mismatch"
    echo
    echo "== root filesystem =="
    echo "--- fstab:"
    cat /mnt/rootfs/etc/fstab
    grep -q "PARTUUID=$DISK_ID-01" /mnt/rootfs/etc/fstab \
        && echo "OK: fstab boot PARTUUID" || echo "FAIL: fstab boot PARTUUID"
    echo "--- inittab getty lines:"
    grep getty /mnt/rootfs/etc/inittab
    echo "--- keymap:"
    ls /mnt/rootfs/usr/share/keymaps/ | grep tca8418 || echo "FAIL: keymap missing"
    echo "--- font:"
    ls /mnt/rootfs/usr/share/consolefonts/ | grep cpz || echo "FAIL: font missing"
    grep -q '^CONSOLE=/dev/tty1' /mnt/rootfs/etc/local.d/console.start \
        && grep -q 'loadkeys -C "\$CONSOLE"' /mnt/rootfs/etc/local.d/console.start \
        && echo "OK: loadkeys bound to tty1" \
        || echo "FAIL: loadkeys has no console (-C)"
    # v0.8: keymap must match the ACTUAL keycap legends (measured on
    # hardware), not M5's design table. SYM+N prints / per the cap.
    grep -q 'cpz-sym-keymap.map' /mnt/rootfs/etc/local.d/console.start \
        && echo "OK: console.start loads the keycap-corrected keymap" \
        || echo "FAIL: console.start still loads the stock M5 keymap"
    grep -q '^keycode 216 = slash' /mnt/rootfs/usr/share/keymaps/cpz-sym-keymap.map \
        && echo "OK: SYM+N is slash (matches keycap)" \
        || echo "FAIL: SYM+N binding wrong (keycap says /)"
    grep -q '^keycode 195 = underscore' /mnt/rootfs/usr/share/keymaps/cpz-sym-keymap.map \
        && echo "OK: SYM+E is underscore (matches keycap)" \
        || echo "FAIL: SYM+E binding wrong (keycap says _)"
    # OpenRC's local service skips non-executable *.start files WITHOUT any
    # message. v0.1..v0.3 shipped 0600 and the keymap never loaded.
    [ -x /mnt/rootfs/etc/local.d/console.start ] \
        && echo "OK: console.start is executable (local service will run it)" \
        || echo "FAIL: console.start not executable — local service ignores it"
    [ -r /mnt/rootfs/etc/profile.d/cpz-status.sh ] \
        && echo "OK: cpz-status.sh readable by users" \
        || echo "FAIL: cpz-status.sh not readable (0600 root-only)"
    [ -x /mnt/rootfs/usr/local/bin/cpzdiag ] \
        && echo "OK: cpzdiag present and executable" \
        || echo "FAIL: cpzdiag missing or not executable"
    [ -d /mnt/rootfs/boot ] \
        && echo "OK: /boot mountpoint exists" \
        || echo "FAIL: no /boot dir — localmount fails, cpzdiag cannot report"
    # /.dockerenv makes OpenRC's container autodetect skip every
    # `keyword -docker` service (sysfs, udev, localmount, hostname...).
    # v0.2..v0.6 shipped it accidentally via docker export.
    [ ! -e /mnt/rootfs/.dockerenv ] \
        && echo "OK: no /.dockerenv (OpenRC will run ALL services)" \
        || echo "FAIL: /.dockerenv present — OpenRC thinks it is a container"
    # v0.12.1: dwc2 host-only — ethernet + USB-A. The serial gadget is
    # sacrificed (wifi ssh is the remote path); otg/peripheral modes
    # are documented dead ends in config.txt.
    grep -q "dtoverlay=dwc2,dr_mode=host" /mnt/boot/config.txt \
        && echo "OK: dwc2 in host mode (ethernet + USB-A)" \
        || echo "FAIL: dwc2 not host — ethernet cannot come up"
    grep -q "v0FE6p9900" /mnt/rootfs/lib/modules/$KVER/modules.alias \
        && echo "OK: SR9900 ethernet autoload alias present" \
        || echo "FAIL: SR9900 usb alias missing — patched r8152 not installed"
    grep -q "^r8152$" /mnt/rootfs/etc/modules \
        && echo "OK: r8152 force-loaded at boot" \
        || echo "FAIL: r8152 not in /etc/modules"
    grep -q "^#ttyGS0" /mnt/rootfs/etc/inittab \
        && echo "OK: ttyGS0 getty disabled (matches host mode)" \
        || echo "FAIL: ttyGS0 getty enabled without a gadget UDC"
    grep -q "ttyGS0" /mnt/rootfs/etc/inittab \
        && echo "OK: getty on ttyGS0 (USB serial login)" \
        || echo "FAIL: no getty on ttyGS0"
    # v0.10: expander READY handshake — the actual LED fix
    grep -q "i2cset -f -y 1 0x4f 0xb0 1" /mnt/rootfs/etc/local.d/cpz-leds.start \
        && echo "OK: LED fix = expander READY handshake" \
        || echo "FAIL: LED fix missing the READY write"
    grep -q "rfkill unblock all" /mnt/rootfs/etc/local.d/cpz-wifi.start \
        && echo "OK: rfkill unblock at boot" \
        || echo "FAIL: no rfkill unblock — wifi soft-blocked every boot"
    grep -q "mmcblk0p1" /mnt/rootfs/etc/fstab \
        && echo "OK: /boot mounted by device name" \
        || echo "FAIL: fstab still uses PARTUUID (busybox cannot resolve)"
    grep -q "^auto wlan0" /mnt/rootfs/etc/network/interfaces \
        && echo "OK: wlan0 auto at boot" \
        || echo "FAIL: wlan0 not enabled in interfaces"
    grep -q "ssid=" /mnt/rootfs/etc/wpa_supplicant/wpa_supplicant.conf \
        && echo "OK: wifi credentials baked in" \
        || echo "FAIL: no network block in wpa conf"
    # v0.13: audio + bluetooth, field-verified on hardware
    [ -s /mnt/rootfs/var/lib/alsa/asound.state ] \
        && grep -q ES8389 /mnt/rootfs/var/lib/alsa/asound.state \
        && echo "OK: ES8389 mixer state shipped" \
        || echo "FAIL: no ES8389 asound.state"
    [ -x /mnt/rootfs/etc/local.d/cpz-audio.start ] \
        && echo "OK: mixer restore runs at boot" \
        || echo "FAIL: cpz-audio.start missing or not executable"
    [ -x /mnt/rootfs/usr/bin/bluetoothctl ] \
        && echo "OK: bluez (bluetoothctl) installed" \
        || echo "FAIL: bluetoothctl missing"
    [ -L /mnt/rootfs/etc/runlevels/default/bluetooth ] \
        && echo "OK: bluetooth service in default runlevel" \
        || echo "FAIL: bluetooth service not enabled"
    # v0.11: persistence layer
    [ -d /mnt/rootfs/cfg ] \
        && echo "OK: /cfg mountpoint exists" \
        || echo "FAIL: no /cfg dir — persistence layer broken"
    [ -x /mnt/rootfs/usr/local/bin/cpz-save ] \
        && echo "OK: cpz-save present" \
        || echo "FAIL: cpz-save missing"
    [ -x /mnt/rootfs/etc/local.d/cpz-restore.start ] \
        && echo "OK: cpz-restore runs at boot" \
        || echo "FAIL: cpz-restore.start missing"
    [ -x /mnt/rootfs/etc/periodic/hourly/cpz-save ] \
        && echo "OK: hourly snapshots scheduled" \
        || echo "FAIL: no hourly cpz-save cron job"
    grep -q "run-parts" /mnt/rootfs/etc/crontabs/root \
        && echo "OK: crond periodic table configured" \
        || echo "FAIL: /etc/crontabs/root missing (crond idle, no snapshots)"
    grep -q "^i2c-dev$" /mnt/rootfs/etc/modules \
        && echo "OK: i2c-dev force-loaded at boot" \
        || echo "FAIL: i2c-dev not in /etc/modules (LED fix + i2c tools dead)"
    grep -q "^brcmfmac$" /mnt/rootfs/etc/modules \
        && echo "OK: brcmfmac force-loaded at boot" \
        || echo "FAIL: brcmfmac not in /etc/modules"
    echo "--- console.start:"
    cat /mnt/rootfs/etc/local.d/console.start
    echo "--- kernel modules ($KVER):"
    ls /mnt/rootfs/lib/modules/$KVER/extra/ 2>/dev/null || echo "FAIL: no extra modules"
    echo "--- M5 extra modules all present:"
    for m in st7789v_m5stack pwm_bl_m5stack tca8418_keypad_m5stack es8389_m5stack \
             bq27xxx_battery.ko bq27xxx_battery_i2c m5ioe1 bmi270_core bmi270_i2c; do
        ls /mnt/rootfs/lib/modules/$KVER/extra/ | grep -q "$m" \
            && echo "OK: $m" || echo "FAIL: $m"
    done
    echo "--- firmware:"
    ls -d /mnt/rootfs/lib/firmware/brcm /mnt/rootfs/lib/firmware/cypress \
          /mnt/rootfs/lib/firmware/synaptics >/dev/null 2>&1 \
        && echo "OK: brcm+cypress+synaptics" || echo "FAIL: firmware dirs"
    [ -s /mnt/rootfs/lib/firmware/regulatory.db ] \
        && echo "OK: regulatory.db" || echo "FAIL: regulatory.db"
    [ -s /mnt/rootfs/lib/firmware/bmi270-init-data.fw ] \
        && echo "OK: bmi270 fw" || echo "FAIL: bmi270 fw"
    echo "--- runlevels:"
    for rl in sysinit boot default shutdown; do
        echo "[$rl]:"; ls /mnt/rootfs/etc/runlevels/$rl/ 2>/dev/null
    done
    # v0.1 shipped without devfs/sysfs/procfs in sysinit: /sys was missing,
    # udev never ran, and there were no /dev/fb* or /dev/input* nodes.
    for s in devfs sysfs procfs udev; do
        [ -L "/mnt/rootfs/etc/runlevels/sysinit/$s" ] \
            && echo "OK: sysinit/$s" || echo "FAIL: sysinit/$s missing"
    done
    for s in root localmount bootmisc hostname; do
        [ -L "/mnt/rootfs/etc/runlevels/boot/$s" ] \
            && echo "OK: boot/$s" || echo "FAIL: boot/$s missing"
    done
    echo "--- dropbear host keys will generate on first boot:"
    ls /mnt/rootfs/etc/dropbear/ 2>/dev/null || echo "(empty — generated at first start)"
    echo "--- shadow (password set):"
    grep -q '^root:\$' /mnt/rootfs/etc/shadow && echo "OK: root password set"
    grep -q '^cpz:' /mnt/rootfs/etc/shadow && echo "OK: cpz user present"
} > $REPO/build/verification-report.txt 2>&1

umount /mnt/boot /mnt/rootfs
losetup -d "$LO"
grep -c FAIL $REPO/build/verification-report.txt >/dev/null && {
    echo "VERIFICATION FAILURES:"; grep FAIL $REPO/build/verification-report.txt; exit 1
}
echo "== verification clean =="

echo "== gzip + checksum =="
gzip -9 -c "$IMG" > $OUT/cpz-alpine-$VER.img.gz
( cd $OUT && sha256sum cpz-alpine-$VER.img.gz > cpz-alpine-$VER.img.gz.sha256 )
ls -la $OUT/cpz-alpine-$VER.img.gz*
chown -R 1000:1000 $OUT $REPO/build/verification-report.txt 2>/dev/null || true

echo "== 30-image COMPLETE: $OUT/cpz-alpine-$VER.img.gz =="
