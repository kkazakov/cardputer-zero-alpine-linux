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
#
# v0.21.5: partition nodes are device-class dependent: /dev/mmcblk0p3 and
# /dev/nvme0n1p3, but /dev/sda3. The old `PART="${DEV}3"` built
# /dev/mmcblk03, so after writing p1/p2 the script declared CPZDATA
# "unavailable", exited 0, and left p3 unformatted (field report from an
# internal SD reader). The suffix is now chosen from the disk name, the
# node lookup retries for ~3 s, and a missing node is a hard error with
# the manual mkfs line.

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

# v0.21.5: partition naming differs by device class. mmcblk0 → mmcblk0p3,
# nvme0n1 → nvme0n1p3, but sda → sda3. The old `PART="${DEV}3"` produced
# /dev/mmcblk03, so the CPZDATA step never found the partition it had just
# created and bailed out with "persistence unavailable" (field report from
# an internal SD reader). Suffix `p` when the disk name ends in a digit.
case "$(basename "$DEV")" in
    *[0-9]) PART="${DEV}p3" ;;
    *)      PART="${DEV}3" ;;
esac

# udev can lag behind partx; give the node a moment before giving up.
# `-u` updates an existing entry, `-a` adds a new one — which one is needed
# depends on the driver (mmc/nvme accept -u; loop/partscan only create the
# node on -a), so try both. Failures here are expected once the node exists.
i=0
while [ ! -b "$PART" ] && [ "$i" -lt 10 ]; do
    partx -u --nr 3 "$DEV" 2>/dev/null || true
    partx -a --nr 3 "$DEV" 2>/dev/null || true
    partx -a "$DEV" 2>/dev/null || true
    i=$((i + 1))
    sleep 0.3
done

if [ ! -b "$PART" ]; then
    echo "ERROR: $PART did not appear after re-reading the partition table." >&2
    echo "The card is bootable but has no /cfg yet. Finish it with:" >&2
    echo "  sudo partx -u $DEV && sudo mkfs.ext4 -F -L CPZDATA $PART" >&2
    exit 1
fi

echo "== checking the data filesystem =="
if fsck.ext4 -n "$PART" >/dev/null 2>&1; then
    echo "CPZDATA intact — your data survives this flash."
else
    echo "CPZDATA absent/corrupt (first flash?) — formatting $PART"
    # partx can expose the node a hair before the kernel finishes wiring it
    # up; mkfs then fails with "No such device or address". Settle and retry.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle -t 3 2>/dev/null || true
    fi
    n=0
    until mkfs.ext4 -F -L CPZDATA "$PART"; do
        n=$((n + 1))
        [ "$n" -ge 3 ] && { echo "ERROR: cannot format $PART" >&2; exit 1; }
        sleep 1
    done
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