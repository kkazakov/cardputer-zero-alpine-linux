#!/bin/sh
# build/10-harvest.sh — offline BSP harvest from the M5 stock image.
#
# Runs INSIDE the privileged builder container (alpine + util-linux/e2fsprogs).
# Expected mounts:
#   /work/vendor/stock.img.xz  — the stock CardputerZero image (xztar of a dd)
#   /repo                      — bind mount of the cardputer-zero-alpine checkout
# Writes:
#   /repo/harvest/{boot,modules,firmware,keymaps,config,logs}/ + MANIFEST.sha256
#
# This is Stage 01 of PLAN.md, executed offline against the factory image
# instead of on-device: the stock image is the authoritative BSP source.
set -eu

VENDOR=/work/vendor
IMG="$VENDOR/stock.img"
XZ="$VENDOR/stock.img.xz"
OUT=/repo/harvest

[ -f "$IMG" ] || { xz -dk "$XZ"; }

# --- Partition discovery (DOS label; boot FAT32 first, root ext4 second) ---
# sfdisk -l columns (whitespace-split, empty Boot column collapses):
#   $1=Device $2=Start $3=End $4=Sectors $5=Size $6=Id $7+=Type
BOOT_START=$(sfdisk -l "$IMG" | awk '$7=="W95" && $8~/^FAT32/ {print $2; exit}')
ROOT_START=$(sfdisk -l "$IMG" | awk '$6=="83" && $7=="Linux" {print $2; exit}')
[ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] || { echo "FATAL: cannot parse partition table"; exit 1; }
BOOT_SECT=$(sfdisk -l "$IMG" | awk '$7=="W95" && $8~/^FAT32/ {print $4; exit}')
ROOT_SECT=$(sfdisk -l "$IMG" | awk '$6=="83" && $7=="Linux" {print $4; exit}')

# --- Loop attach + partition device nodes (containers lack udev) ---
LO=$(losetup -f --show -P "$IMG")
BASE=$(basename "$LO")
cleanup() {
    umount /mnt/boot /mnt/root 2>/dev/null || true
    losetup -d "$LO" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[ -e "/dev/$BASE" ] || mknod "/dev/$BASE" b $(cat "/sys/class/block/$BASE/dev" | tr : ' ')
for P in $(ls /sys/class/block | grep "^${BASE}p"); do
    [ -e "/dev/$P" ] || mknod "/dev/$P" b $(cat "/sys/class/block/$P/dev" | tr : ' ')
done
mkdir -p /mnt/boot /mnt/root
mount -o ro "/dev/${BASE}p1" /mnt/boot
mount -o ro "/dev/${BASE}p2" /mnt/root

KVER=$(ls /mnt/root/lib/modules/ | grep -- 'rpi-v8' | head -1)
[ -n "$KVER" ] || { echo "FATAL: no rpi-v8 module tree in stock image"; exit 1; }

# --- Clean output dirs (busybox sh: no brace expansion) ---
rm -rf "$OUT"
mkdir -p "$OUT/boot" "$OUT/modules" "$OUT/firmware" "$OUT/keymaps" "$OUT/config" "$OUT/logs"

echo "== harvesting boot partition (full FAT tree) =="
cp -a /mnt/boot/. "$OUT/boot/"

echo "== harvesting kernel modules: $KVER =="
cp -a "/mnt/root/lib/modules/$KVER" "$OUT/modules/"

echo "== harvesting firmware =="
cp -a /mnt/root/lib/firmware/brcm "$OUT/firmware/"
# brcm nvram/.hcd symlinks resolve into sibling dirs — keep them intact
[ -d /mnt/root/lib/firmware/cypress ] && cp -a /mnt/root/lib/firmware/cypress "$OUT/firmware/"
[ -d /mnt/root/lib/firmware/synaptics ] && cp -a /mnt/root/lib/firmware/synaptics "$OUT/firmware/"
find /mnt/root/lib/firmware -maxdepth 1 -type f \
    \( -iname '*st7789*' -o -iname '*cardputer*' -o -iname '*bmi270*' \) \
    -exec cp -a {} "$OUT/firmware/" \; 2>/dev/null || true

echo "== harvesting keymap =="
cp -a /mnt/root/usr/share/keymaps/. "$OUT/keymaps/" 2>/dev/null || \
    echo "WARN: no /usr/share/keymaps in stock rootfs"

echo "== harvesting stock configs =="
mkdir -p "$OUT/config"
cp -a /mnt/root/etc/modprobe.d "$OUT/config/" 2>/dev/null || true
cp -a /mnt/root/etc/modules-load.d "$OUT/config/" 2>/dev/null || true
cp -a /mnt/root/etc/udev/rules.d "$OUT/config/udev-rules.d" 2>/dev/null || true
[ -f /mnt/root/var/lib/alsa/asound.state ] && \
    cp -a /mnt/root/var/lib/alsa/asound.state "$OUT/config/" || true
[ -f /mnt/root/etc/fstab ] && cp -a /mnt/root/etc/fstab "$OUT/config/fstab.stock"

echo "== writing logs =="
{
    echo "harvested: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel: $KVER"
    echo "image sha256:"
    sha256sum "$XZ"
    echo
    echo "== boot partition top level =="
    ls -la /mnt/boot/
    echo
    echo "== boot DTBs =="
    ls /mnt/boot/ | grep -E '\.dtb$'
    echo
    echo "== boot m5 overlays =="
    ls /mnt/boot/overlays/ | grep -iE 'cardputer|bq27|bmi|st7789|tca8418|es8389|m5ioe' || true
    echo
    echo "== /lib/modules/$KVER top =="
    ls "/mnt/root/lib/modules/$KVER"
    echo
    echo "== extra/ modules =="
    ls -la "/mnt/root/lib/modules/$KVER/extra/" 2>/dev/null || true
    echo
    echo "== stock config.txt =="
    cat /mnt/boot/config.txt
    echo
    echo "== stock cmdline.txt =="
    cat /mnt/boot/cmdline.txt
    echo
    echo "== stock fstab =="
    cat /mnt/root/etc/fstab 2>/dev/null
    echo
    echo "== firmware brcm =="
    ls -la /mnt/root/lib/firmware/brcm/ 2>/dev/null
    echo
    echo "== firmware root-level cpz files =="
    find /mnt/root/lib/firmware -maxdepth 1 -type f \
        \( -iname '*st7789*' -o -iname '*cardputer*' -o -iname '*bmi270*' \) -exec ls -la {} \;
    echo
    echo "== asound.state? =="
    ls -la /mnt/root/var/lib/alsa/ 2>/dev/null || echo none
    echo
    echo "== /lib/firmware root (dirs of interest) =="
    ls -la /mnt/root/lib/firmware/ | head -60
    echo
    echo "== extra module metadata =="
    for ko in /mnt/root/lib/modules/$KVER/extra/*.ko; do
        echo "--- $(basename $ko)"
        modinfo "$ko" 2>/dev/null | grep -E '^(name|vermagic|depends|firmware):' || true
    done
    echo
    echo "== stock initramfs8 module inventory (mkinitfs reference) =="
    gzip -dc /mnt/boot/initramfs8 2>/dev/null | cpio -t 2>/dev/null | grep '\.ko' | sed 's|.*/||' | sort | head -60 || true
    echo
    echo "== all overlays in stock boot =="
    ls /mnt/boot/overlays/
    echo
    echo "== dpkg kernel status =="
    grep -A2 -E "^Package: (linux-image|raspi-firmware)" /mnt/root/var/lib/dpkg/status 2>/dev/null | head -40
} > "$OUT/logs/harvest-report.txt" 2>&1

(cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum) > "$OUT/MANIFEST.sha256"

# hand ownership back to the repo user (host uid/gid 1000)
chown -R 1000:1000 "$OUT" 2>/dev/null || true

echo "== harvest complete =="
du -sh "$OUT"/* | sort -h
echo
echo "MANIFEST lines: $(wc -l < "$OUT/MANIFEST.sha256")"
