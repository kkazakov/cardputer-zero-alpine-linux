#!/bin/sh
# flash-cpz.command — CPZ-Alpine flasher for macOS (double-click).
#
# This is the macOS counterpart of flash-cpz.sh. It always verifies the
# SHA-256 first. If the target card already has the CPZ-Alpine layout
# (p1 @ 16 MiB, p2 @ 264 MiB, CPZDATA p3 @ 4 GiB), it keeps the existing
# partition table so /cfg and the user's files survive. A blank/foreign
# card gets a clean install; on that first flash no CPZDATA partition is
# created (use the Linux flasher once if you want persistence).
set -eu
cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

IMG=$(ls -t cpz-alpine-*.img.gz 2>/dev/null | head -1 || true)
[ -n "$IMG" ] || die "no cpz-alpine-*.img.gz in this folder"
[ -f "$IMG.sha256" ] || die "missing $IMG.sha256"
say "image:   $IMG"
say "checking SHA-256..."
(cd "$(dirname "$IMG")" && shasum -a 256 -c "$(basename "$IMG").sha256") \
    || die "checksum mismatch — refusing to flash"

say ""
say "Removable disks (use the diskN identifier, NOT a partition like disk4s1):"
diskutil list
say ""
printf 'Target disk (e.g. disk4, NOT disk0): '
read -r DEV
DEV=${DEV#/dev/}
case "$DEV" in
    disk[1-9]|disk[1-9][0-9]*) ;;
    *) die "invalid disk identifier: $DEV" ;;
esac
[ "$DEV" != "disk0" ] || die "refusing disk0 (the boot disk)"
INFO=$(diskutil info "$DEV" 2>/dev/null) || die "no such disk: $DEV"
printf '%s\n' "$INFO" | grep -q 'Internal: *Yes' && die "refusing an internal disk"
printf '%s\n' "$INFO" | grep -q 'Virtual: *Yes' && die "refusing a virtual disk"

BYTES=$(printf '%s\n' "$INFO" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -1)
[ -n "$BYTES" ] || die "cannot determine the disk size"
TOTAL=$((BYTES / 512))
[ "$TOTAL" -gt 4194304 ] || die "disk is smaller than 2 GiB"

say ""
printf '%s\n' "$INFO" | grep -E 'Device / Media Name|Disk Size|Removable Media|Internal' || true
say ""
say "ALL DATA ON /dev/$DEV WILL BE OVERWRITTEN."
printf 'Type ERASE to continue: '
read -r OK
[ "$OK" = "ERASE" ] || die "aborted"

TMP=$(mktemp -d /tmp/cpz-flash.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
sudo -v || die "administrator access is required"
diskutil unmountDisk "/dev/$DEV" >/dev/null || die "cannot unmount /dev/$DEV"

# Read the existing MBR and decide whether it is a CPZ-Alpine layout.
dd if="/dev/r$DEV" of="$TMP/mbr" bs=512 count=1 2>/dev/null
le32() { od -An -tu4 -j "$1" -N 4 "$TMP/mbr" | tr -d ' '; }
u8()   { od -An -tu1 -j "$1" -N 1 "$TMP/mbr" | tr -d ' '; }

PRESERVE=0
SIG=$(od -An -tx1 -j 510 -N 2 "$TMP/mbr" | tr -d ' \n')
if [ "$SIG" = "55aa" ]; then
    P1S=$(le32 454); P1N=$(le32 458)
    P2S=$(le32 470); P2N=$(le32 474)
    P3S=$(le32 486); P3N=$(le32 490)
    P3T=$(u8 482)
    if [ "$P1S" = "16384" ] && [ "$P1N" = "524288" ] \
       && [ "$P2S" = "540672" ] && [ "$P2N" = "3145728" ] \
       && [ "$P3T" = "131" ] && [ "$P3S" = "8388608" ] \
       && [ "$P3N" -gt 0 ] && [ $((P3S + P3N)) -le "$TOTAL" ]; then
        PRESERVE=1
    fi
fi

if [ "$PRESERVE" = "1" ]; then
    say "CPZ-Alpine layout found: preserving CPZDATA and the partition table."
else
    say "No CPZ-Alpine layout found: clean install."
    say "NOTE: a clean install has no CPZDATA partition, so /cfg persistence"
    say "      is unavailable until you flash once with flash-cpz.sh on Linux."
fi

say "writing $IMG to /dev/r$DEV ..."
gunzip -c "$IMG" | sudo dd of="/dev/r$DEV" bs=1048576
if [ "$PRESERVE" = "1" ]; then
    say "restoring the original partition table (CPZDATA entry)..."
    sudo dd if="$TMP/mbr" of="/dev/r$DEV" bs=512 count=1 conv=notrunc
fi
sync
diskutil eject "/dev/$DEV" >/dev/null 2>&1 || true
say "done. Insert the card into the CardputerZero and power on."