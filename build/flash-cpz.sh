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
#
# v0.21.0 additions:
#   - verifies the adjacent .sha256 before touching the card
#   - grows the CPZDATA filesystem when the partition is larger than it
#     (a card that was flashed on a smaller card, then moved to a bigger
#     one). The device-side cpz-grow.start does the same at boot, so this
#     is mostly for the first flash on a brand-new card.
#   - the --delete of the stale p3 entry now actually runs (the old line
#     passed --no-update, which sfdisk does not have, so it failed
#     silently and a reflash created an overlapping p4 entry)
#   - cards written with dd/Imager/balenaEtcher/flash-cpz.bat get their
#     CPZDATA created by the device itself on the first boot (one extra
#     reboot); this script is still the recommended path because it is
#     offline and does not reboot the card.

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
# Zap any stale table entry for p3, then append a fresh one at the fixed
# offset. v0.21.0: the old line passed --no-update, which sfdisk does not
# have, so the delete always failed (hidden by || true) and reflashing a
# card that already had CPZDATA created an overlapping p4 entry.
sfdisk --no-reread "$DEV" --delete 3 2>/dev/null || true
echo "8388608,," | sfdisk --no-reread --append "$DEV" >/dev/null || {
    echo "ERROR: sfdisk could not create the CPZDATA partition entry"; exit 1; }

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

# v0.21.0: the partition runs to the end of the card, but an ext4
# filesystem created on a smaller card keeps its old size. Grow it here
# while the card is offline (the device-side cpz-grow.start does the same
# thing at boot).
echo "== CPZDATA filesystem size =="
PARTBYTES=$(blockdev --getsize64 "$PART" 2>/dev/null)
if [ -z "$PARTBYTES" ]; then
    PB=$(cat "/sys/block/$(basename "$DEV")/$(basename "$PART")/size" 2>/dev/null)
    [ -n "$PB" ] && PARTBYTES=$((PB * 512))
fi
if [ -n "$PARTBYTES" ] && command -v resize2fs >/dev/null 2>&1 && command -v dumpe2fs >/dev/null 2>&1; then
    BC=$(dumpe2fs -h "$PART" 2>/dev/null | awk '/^Block count:/ {print $3}')
    BS=$(dumpe2fs -h "$PART" 2>/dev/null | awk '/^Block size:/ {print $3}')
    if [ -n "$BC" ] && [ -n "$BS" ] && [ "$((BC * BS))" -lt "$PARTBYTES" ]; then
        echo "filesystem $((BC * BS / 1048576)) MiB < partition $((PARTBYTES / 1048576)) MiB — growing it"
        e2fsck -f -y "$PART" >/dev/null 2>&1 || true
        resize2fs "$PART" || echo "WARNING: resize2fs failed, CPZDATA keeps its old size"
    else
        echo "CPZDATA already covers the partition"
    fi
else
    echo "note: resize2fs/dumpe2fs unavailable — CPZDATA keeps its current size"
fi

sync
echo
echo "done. Boot the card: everything under /cfg restores automatically."