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

# v0.21.8: safety net. The flasher must never be able to destroy an
# existing /cfg. Before writing anything:
#   - if p3 already carries an ext4 filesystem, repair it read-only and
#     copy its snapshot into the current directory (a real backup the
#     user can restore from even if the card is later erased);
#   - refuse to continue if that filesystem cannot be mounted, unless
#     the user explicitly passes --format.
# After the write, an ext4 signature is kept; mkfs only happens when
# there was no ext4 signature before the write either.
FORMAT=0
for a in "$@"; do [ "$a" = "--format" ] && FORMAT=1; done
command -v blkid >/dev/null 2>&1 || {
    echo "ERROR: blkid not found; refusing to flash without a CPZDATA check" >&2
    exit 1
}
case "$(basename "$DEV")" in
    *[0-9]) PART_PRE="${DEV}p3" ;;
    *)      PART_PRE="${DEV}3" ;;
esac
HAD_EXT4=0
BK="cpz-cfg-backup-$(date +%Y%m%d-%H%M%S)"
if [ -b "$PART_PRE" ] && [ "$(blkid -o value -s TYPE "$PART_PRE" 2>/dev/null || true)" = "ext4" ]; then
    HAD_EXT4=1
    echo "== existing CPZDATA detected — protecting it =="
    if ! fsck.ext4 -n "$PART_PRE" >/dev/null 2>&1; then
        echo "   journal needs replay — repairing (not formatting)"
        e2fsck -f -y "$PART_PRE" >/dev/null 2>&1 || true
    fi
    if ! fsck.ext4 -n "$PART_PRE" >/dev/null 2>&1 && [ "$FORMAT" = 0 ]; then
        echo "ERROR: $PART_PRE is ext4 but cannot be repaired; refusing to format it." >&2
        echo "       Re-run with --format to erase /cfg deliberately." >&2
        exit 1
    fi
    if mkdir -p "$BK.mnt" && mount -o ro "$PART_PRE" "$BK.mnt" 2>/dev/null; then
        mkdir -p "$BK"
        for f in save.tar.gz save.tar.gz.prev shadow-users pkglist.txt world repositories ntp; do
            [ -f "$BK.mnt/$f" ] && cp -p "$BK.mnt/$f" "$BK/" 2>/dev/null || true
        done
        # local packages installed from .apk files are not in any repo
        [ -d "$BK.mnt/apk" ] && cp -a "$BK.mnt/apk" "$BK/" 2>/dev/null || true
        [ -d "$BK.mnt/apk-keys" ] && cp -a "$BK.mnt/apk-keys" "$BK/" 2>/dev/null || true
        umount "$BK.mnt" || true
        rmdir "$BK.mnt" 2>/dev/null || true
        echo "   /cfg snapshot backed up to $PWD/$BK"
        [ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$BK" 2>/dev/null || true
    else
        rmdir "$BK.mnt" 2>/dev/null || true
        if [ "$FORMAT" = 0 ]; then
            echo "ERROR: cannot mount $PART_PRE read-only to back it up; refusing to flash." >&2
            echo "       Re-run with --format to erase /cfg deliberately." >&2
            exit 1
        fi
    fi
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
do_mkfs()
{
    p=$1
    # partx can expose the node a hair before the kernel finishes wiring it
    # up; mkfs then fails with "No such device or address". Settle and retry.
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle -t 3 2>/dev/null || true
    fi
    n=0
    until mkfs.ext4 -F -L CPZDATA "$p"; do
        n=$((n + 1))
        [ "$n" -ge 3 ] && { echo "ERROR: cannot format $p" >&2; exit 1; }
        sleep 1
    done
}

PTYPE=$(blkid -o value -s TYPE "$PART" 2>/dev/null || true)
if [ "$FORMAT" = 1 ]; then
    echo "--format requested — erasing CPZDATA on $PART"
    do_mkfs "$PART"
elif [ "$PTYPE" = "ext4" ]; then
    if ! fsck.ext4 -n "$PART" >/dev/null 2>&1; then
        # v0.21.6: a dirty journal is NOT corruption. `fsck -n` cannot replay
        # it and returns non-zero; the old code read that as "format", so a
        # reflash after an unclean shutdown destroyed a perfectly good /cfg
        # (field report: Wi-Fi/Tailscale/passwords/SSH all reset). Repair it.
        echo "CPZDATA needs a journal replay/repair — repairing, NOT formatting"
        e2fsck -f -y "$PART" >/dev/null 2>&1 || true
    fi
    if fsck.ext4 -n "$PART" >/dev/null 2>&1; then
        echo "CPZDATA intact — your data survives this flash."
    else
        echo "ERROR: $PART is ext4 but cannot be repaired; refusing to format it." >&2
        echo "       Re-run with --format to erase /cfg deliberately." >&2
        exit 1
    fi
elif [ "$HAD_EXT4" = 1 ]; then
    # The pre-write check saw ext4, but the freshly re-created node is not
    # readable yet. Never turn that into a silent mkfs: abort and let the
    # user re-run (the backup from the pre-check is already on disk).
    echo "ERROR: CPZDATA was ext4 before the write but $PART is not visible yet." >&2
    echo "       Refusing to format it. Re-run the script (the node should be ready)." >&2
    exit 1
else
    echo "CPZDATA has no ext4 signature (first flash) — formatting $PART"
    do_mkfs "$PART"
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

# v0.21.10: put the pre-flash snapshot back. The e2fsck replay/repair above
# can revert the last (unflushed) save.tar.gz to an older generation — the
# field failure was a 30,346-byte archive in the backup but a 23,527-byte
# one restored after the flash. The backup taken before the write is the
# newest complete snapshot, so write it back instead of booting the older
# one. This also carries /cfg/ntp (the NTP preference) across the flash.
if [ "$HAD_EXT4" = 1 ] && [ -f "$BK/save.tar.gz" ]; then
    echo "== restoring the pre-flash /cfg snapshot =="
    MNT=/tmp/cpz-cfg-rewrite.$$
    mkdir -p "$MNT"
    if mount -t ext4 -o rw "$PART" "$MNT"; then
        for f in save.tar.gz save.tar.gz.prev shadow-users pkglist.txt world repositories ntp; do
            [ -f "$BK/$f" ] && cp -p "$BK/$f" "$MNT/$f" 2>/dev/null || true
        done
        if [ -d "$BK/apk" ]; then
            mkdir -p "$MNT/apk"
            cp -a "$BK/apk/." "$MNT/apk/" 2>/dev/null || true
        fi
        if [ -d "$BK/apk-keys" ]; then
            mkdir -p "$MNT/apk-keys"
            cp -a "$BK/apk-keys/." "$MNT/apk-keys/" 2>/dev/null || true
        fi
        chmod 600 "$MNT/save.tar.gz" "$MNT/save.tar.gz.prev" \
            "$MNT/shadow-users" "$MNT/pkglist.txt" 2>/dev/null || true
        sync
        umount "$MNT" || echo "WARNING: could not unmount $MNT"
    else
        echo "WARNING: could not mount $PART rw to restore the snapshot"
    fi
    rmdir "$MNT" 2>/dev/null || true
fi

echo
echo "done. Boot the card: everything under /cfg restores automatically."