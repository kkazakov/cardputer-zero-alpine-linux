#!/bin/sh
# flash-cpz.sh — flash CPZ-Alpine AND preserve the CPZDATA partition
#
# Usage:  sudo ./flash-cpz.sh /dev/sdX [image.img.gz]
#
# Why not plain dd: the image carries only partitions 1-2. This script
# writes them, then re-creates the CPZDATA partition entry at the fixed
# 4 GiB offset (8388608 sectors). The data partition's sectors are never
# touched, so /cfg (your /etc, /root, /home/cpz snapshots and package
# list) survives every reflash. Formatted ONLY when missing or corrupt.
#
# Safety: refuses non-block devices; unmounts any auto-mounted
# partitions of the target first (desktop environments automount FAT
# partitions the moment the card is inserted).

set -eu

DEV=${1:?usage: sudo ./flash-cpz.sh /dev/sdX [image.img.gz]}
# v0.12.2: default to the NEWEST image in the current directory.
# Earlier versions hardcoded a name — running the script without an
# argument silently flashed that (old) version.
if [ -n "${2:-}" ]; then
    IMG=$2
else
    IMG=$(ls -t cpz-alpine-*.img.gz 2>/dev/null | head -1)
fi
[ -n "$IMG" ] || { echo "ERROR: no cpz-alpine-*.img.gz found here"; exit 1; }
echo "flashing: $IMG"

[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "ERROR: run with sudo"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: image $IMG not found"; exit 1; }

# v0.20.1 release: verify the adjacent checksum before touching the card.
if [ -f "$IMG.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    IMG_DIR=$(dirname "$IMG")
    IMG_BASE=$(basename "$IMG")
    echo "== verifying checksum =="
    ( cd "$IMG_DIR" && sha256sum -c "$IMG_BASE.sha256" ) \
        || { echo "ERROR: checksum mismatch — refusing to flash"; exit 1; }
fi

# unmount every mounted partition of the target
MOUNTED=$(awk -v d="$DEV" '$1 ~ "^"d {print $1}' /proc/mounts)
if [ -n "$MOUNTED" ]; then
    echo "== unmounting target partitions =="
    for m in $MOUNTED; do
        echo "   umount $m"
        umount "$m" || { echo "ERROR: cannot unmount $m (busy?)"; exit 1; }
    done
fi
if awk -v d="$DEV" '$1 ~ "^"d {found=1} END{exit !found}' /proc/mounts; then
    echo "ERROR: $DEV still has mounted partitions"; exit 1
fi

echo "== flashing $IMG -> $DEV =="
case "$IMG" in
    *.gz) gunzip -c "$IMG" | dd of="$DEV" bs=4M conv=fsync status=progress ;;
    *)    dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress ;;
esac

echo
echo "== recreating CPZDATA partition (4 GiB offset) =="
# zap any stale table entry for p3, then append fresh at the fixed offset
sfdisk --no-reread --no-update "$DEV" --delete 3 2>/dev/null || true
echo "8388608,," | sfdisk --no-reread --append "$DEV" >/dev/null

# re-read the table without disturbing mounted media
partx -u --nr 3 "$DEV" 2>/dev/null || true
PART="${DEV}3"

if [ ! -b "$PART" ]; then
    echo "WARNING: $PART did not appear — persistence unavailable this time."
    echo "Wi-Fi etc. still work; run flash-cpz.sh again from a desktop."
    exit 0
fi

echo "== checking the data filesystem =="
if fsck.ext4 -n "$PART" >/dev/null 2>&1; then
    echo "CPZDATA intact — your data survives this flash."
else
    echo "CPZDATA absent/corrupt (first flash?) — formatting $PART"
    mkfs.ext4 -F -L CPZDATA "$PART"
fi

sync
echo
echo "done. Boot the card: everything under /cfg restores automatically."