#!/bin/sh
# build/test-cpz-grow.sh — container simulation of rootfs-overlay/etc/local.d/cpz-grow.start
#
# The script's real job (partition tables on a mounted SD card, ext4
# resize on the running device) cannot be tested by grepping, and a bug
# in it costs the user a reboot loop on a card they cannot re-flash
# without a Linux desktop. So the state machine is driven here instead:
#   - a real 8 GiB sparse loop disk with the real CPZ MBR layout (p1 at
#     16384, p2 at 540672) is the "card", and sfdisk really writes to it;
#   - /sys/block/mmcblk0 is faked, which is exactly what lets us simulate
#     "the kernel does not know about p3 yet" and "p3 ends before the end
#     of the card" — states a loop device cannot produce on its own;
#   - real loop devices stand in for the CPZDATA partition, so mkfs.ext4 /
#     resize2fs / blkid run for real and their effects are asserted;
#   - /dev/console is bind-mounted to a log file (say() writes there) and
#     `reboot` is a stub, so the reboot-then-continue path is observable.
#
# Run:  docker run --privileged -v "$REPO_HOST:/repo" -v "$REPO_HOST/build:/mnt/build" \
#           alpine:3.24 sh /repo/build/test-cpz-grow.sh
#
# (the second mount only exists to give the bind-mount of /dev/console a
# host-side file to start from; anything else works too)
#
# Exit 0 = every scenario matched. Any FAIL line is a cpz-grow bug.
# The CPZ_GROW_* overrides exist only for this harness — never set them
# on a device.
set -u

G=/repo/rootfs-overlay/etc/local.d/cpz-grow.start
T=/tmp/cztest
sh -n "$G" || { echo "FAIL: cpz-grow.start has a syntax error"; exit 1; }

apk add --no-cache sfdisk e2fsprogs e2fsprogs-extra blkid util-linux >/dev/null 2>&1 || {
    echo "FAIL: harness could not install its tools"; exit 1; }

rm -rf "$T"; mkdir -p "$T/bin" "$T/sys/block/mmcblk0" "$T/cfg"
# reboot is the only fake in the control flow
echo '#!/bin/sh
echo REBOOT-CALLED' > "$T/bin/reboot"
chmod 755 "$T/bin/reboot"
export PATH="$T/bin:$PATH"
# cpz-grow.start talks to the user through /dev/console (the serial
# console on the device); make it a capture target so the harness can read
# what the script said
echo > "$T/console.log"
if [ -e /dev/console ]; then
    mount --bind "$T/console.log" /dev/console 2>/dev/null && CONSOLE="$T/console.log" \
        || { echo "WARN: /dev/console cannot be captured, say() output is lost"; CONSOLE=; }
else
    echo > /dev/console
    CONSOLE=/dev/console
fi

DISKSECT=16777216          # 8 GiB card
P3START=8388608            # fixed 4 GiB CPZDATA offset
FAILS=0

# /dev/loop* on a privileged container are the host's nodes: numbers can be
# missing, and an aborted run may have left devices attached. Always take a
# brand-new number past the highest one and mknod it — reuse is what made
# this harness lie to itself once (a device still backed by the previous
# scenario's formatted image).
cleanup_our_loops() {
    losetup -a 2>/dev/null | grep -E '/tmp/(cztest|lt)\.img' | cut -d: -f1 | while read -r L; do
        losetup -d "$L" 2>/dev/null
    done
}
cleanup_our_loops
NEXTLOOP=
free_loop() {
    NEXTLOOP=$((NEXTLOOP + 1))
    N=$(ls /dev/loop[0-9]* 2>/dev/null | sed 's|.*loop||' | grep -E '^[0-9]+$' | sort -n | tail -1)
    N=$((N + NEXTLOOP))
    mknod /dev/loop$N b 7 $N 2>/dev/null || { echo "FAIL: mknod /dev/loop$N"; exit 1; }
    echo /dev/loop$N
}
attach() {
    LO=$(free_loop)
    losetup "$LO" "$1" || { echo "FAIL: could not attach $1 to $LO"; exit 1; }
    echo "$LO"
}
detach() { losetup -d "$1" >/dev/null 2>&1; }
sparse() { truncate -s "$2" "$1"; }

echo "== card: 8 GiB sparse loop with the real CPZ MBR layout"
sparse "$T/disk.img" 8589934592
DISK=$(attach "$T/disk.img")
# --force: sfdisk warns about the 8 MiB gap and the gap past p2, which is
# exactly the CPZ layout we are testing
printf "16384,524288,c\n540672,3145728,83\n" \
    | sfdisk --no-reread --no-tell-kernel --force "$DISK" >/dev/null 2>&1 || {
        echo "FAIL: harness could not write the CPZ MBR"; exit 1; }
printf "%s\n" "$DISKSECT" > "$T/sys/block/mmcblk0/size"
mkdir -p "$T/sys/block/mmcblk0/mmcblk0p1" "$T/sys/block/mmcblk0/mmcblk0p2"
printf "16384\n" > "$T/sys/block/mmcblk0/mmcblk0p1/start"
printf "540672\n" > "$T/sys/block/mmcblk0/mmcblk0p2/start"
P3DEV=; P3LOOP=

# fake sysfs state for the CPZDATA partition — this is the whole trick:
# the harness decides what the kernel "knows", which is the only way to
# produce the "not visible yet" and "ends before the end of the card"
# states a loop device cannot produce on its own
fake_p3() {
    rm -rf "$T/sys/block/mmcblk0/mmcblk0p3"
    [ "$1" = none ] && return 0
    mkdir -p "$T/sys/block/mmcblk0/mmcblk0p3"
    printf "%s\n" "$1" > "$T/sys/block/mmcblk0/mmcblk0p3/start"
    printf "%s\n" "$2" > "$T/sys/block/mmcblk0/mmcblk0p3/size"
}
attach_p3() {
    [ -n "$P3LOOP" ] && { losetup -d "$P3LOOP" 2>&1 || echo "  WARN: could not detach $P3LOOP"; }
    rm -f "$T/p3.img"
    sparse "$T/p3.img" "$1"
    P3LOOP=$(attach "$T/p3.img"); P3DEV="$P3LOOP"
    echo "  note: CPZDATA on $P3LOOP, backing=$(losetup -a 2>/dev/null | grep "^$P3LOOP:" | cut -d'(' -f2 | tr -d ')')"
}
# ext4 filesystem deliberately smaller than the device: the "card moved to
# a bigger reader" state that resize2fs exists for
attach_p3_small_fs() {
    [ -n "$P3LOOP" ] && detach "$P3LOOP"
    rm -f "$T/p3.img"
    dd if=/dev/zero of="$T/p3.img" bs=1M count=1024 status=none   # 1 GiB FS
    mkfs.ext4 -q -F -L CPZDATA "$T/p3.img" >/dev/null
    truncate -s "$1" "$T/p3.img"                                  # device grows
    P3LOOP=$(attach "$T/p3.img"); P3DEV="$P3LOOP"
}
run_grow() {
    [ -n "$CONSOLE" ] && : > "$CONSOLE"; rm -f "$T/out"
    CPZ_GROW_DEV="$DISK" CPZ_GROW_P3="$P3DEV" CPZ_GROW_SYS="$T/sys/block/mmcblk0" \
    CPZ_GROW_FLAG="$T/pending" CPZ_GROW_CFG="$T/cfg" CPZ_GROW_BACKUP="$T/backup.tar.gz" \
    sh "$G" > "$T/out" 2>&1
    [ -n "$CONSOLE" ] && cat "$CONSOLE" >> "$T/out"
}
check()   { grep -q "$1" "$T/out" && echo "  ok: said '$1'" || { echo "  FAIL: expected '$1'"; echo "  ---- script said:"; cat "$T/out"; FAILS=$((FAILS+1)); }; }
nocheck() { grep -q "$1" "$T/out" && { echo "  FAIL: unexpected '$1'"; FAILS=$((FAILS+1)); } || echo "  ok: did not say '$1'"; }
reset_mbr() {
    printf "16384,524288,c\n540672,3145728,83\n" \
        | sfdisk --no-reread --no-tell-kernel --force "$DISK" >/dev/null 2>&1
    rm -f "$T/pending"
}
# read the MBR p3 entry straight out of the card image (no sfdisk output
# format assumptions): little-endian 32-bit start/sectors at 486/490
assert_p3_at_card_end() {
    set -- $(od -An -tu4 -j 486 -N 8 "$T/disk.img" | tr -s ' ')
    S=$1; N=$2
    if [ "$S" = "$P3START" ] && [ "$((S + N))" = "$DISKSECT" ]; then
        echo "  ok: MBR p3 = $S..$((S + N - 1)) (end of card)"
    else
        echo "  FAIL: MBR p3 = $S..$((S + N - 1)), wanted $P3START..$((DISKSECT - 1))"
        FAILS=$((FAILS+1))
    fi
}
# slot 4 must stay empty: a stale p3 entry that is not deleted first makes
# --append create an overlapping p4 (the v0.20.1 flasher bug)
assert_no_p4() {
    set -- $(od -An -tu1 -j 494 -N 1 "$T/disk.img" | tr -s ' ') $(od -An -tu4 -j 498 -N 4 "$T/disk.img" | tr -s ' ')
    T4=$1; N4=$2
    if [ "$T4" = "0" ] || [ "$N4" = "0" ]; then echo "  ok: no overlapping p4";
    else echo "  FAIL: overlapping p4"; FAILS=$((FAILS+1)); fi
}

echo
echo "== S1 fresh card: append CPZDATA to the end of the card, reboot once"
reset_mbr; fake_p3 none; attach_p3 1048576
run_grow
check "creating CPZDATA"; check "REBOOT-CALLED"
[ "$(cat "$T/pending" 2>/dev/null)" = append ] && echo "  ok: flag=append" || { echo "  FAIL: flag not append"; FAILS=$((FAILS+1)); }
assert_p3_at_card_end; assert_no_p4

echo
echo "== S2 append did not reach the kernel: give up, do not reboot forever"
reset_mbr; fake_p3 none; attach_p3 1048576
printf "append\n" > "$T/pending"
run_grow
check "did not see it"; nocheck "REBOOT-CALLED"
[ -f "$T/pending" ] && { echo "  FAIL: stale flag left behind"; FAILS=$((FAILS+1)); } || echo "  ok: flag cleared"

echo
echo "== S3 kernel now shows CPZDATA, still empty, we created it: mkfs"
reset_mbr; fake_p3 "$P3START" $((DISKSECT - P3START)); attach_p3 4294967296
printf "append\n" > "$T/pending"
run_grow
check "formatting the new CPZDATA"
[ "$(blkid -o value -s TYPE "$P3DEV" 2>/dev/null)" = ext4 ] && echo "  ok: CPZDATA formatted as ext4" || { echo "  FAIL: no ext4"; FAILS=$((FAILS+1)); }
[ "$(blkid -o value -s LABEL "$P3DEV" 2>/dev/null)" = CPZDATA ] && echo "  ok: label CPZDATA" || { echo "  FAIL: wrong label"; FAILS=$((FAILS+1)); }
[ -f "$T/pending" ] && { echo "  FAIL: flag left behind after mkfs"; FAILS=$((FAILS+1)); } || echo "  ok: flag cleared"

echo
echo "== S4 CPZDATA with no filesystem that we did NOT create: leave it alone"
reset_mbr; fake_p3 "$P3START" $((DISKSECT - P3START)); attach_p3 4294967296
run_grow
check "no filesystem"; check "leaving it alone"
[ -z "$(blkid -o value -s TYPE "$P3DEV" 2>/dev/null)" ] && echo "  ok: foreign data not formatted" || { echo "  FAIL: formatted a partition we did not create"; FAILS=$((FAILS+1)); }

echo
echo "== S5 filesystem smaller than the partition: resize, keep the snapshot"
reset_mbr; fake_p3 12582912 4194304        # 2 GiB ending exactly at the card end
attach_p3_small_fs 2147483648
mount -t ext4 "$P3DEV" "$T/cfg"
echo keep-me > "$T/cfg/marker.txt"
echo snapshot > "$T/cfg/save.tar.gz"
umount "$T/cfg"
run_grow
check "growing the CPZDATA filesystem"; check "CPZDATA resized"
mount -t ext4 "$P3DEV" "$T/cfg"
grep -q keep-me "$T/cfg/marker.txt" && echo "  ok: data survived the resize" || { echo "  FAIL: resize lost data"; FAILS=$((FAILS+1)); }
grep -q snapshot "$T/cfg/save.tar.gz" && echo "  ok: snapshot survived the resize" || { echo "  FAIL: resize lost the snapshot"; FAILS=$((FAILS+1)); }
umount "$T/cfg"
[ -f "$T/backup.tar.gz" ] && { echo "  FAIL: parked snapshot not cleaned up"; FAILS=$((FAILS+1)); } || echo "  ok: parked snapshot cleaned up"
[ -f "$T/pending" ] && { echo "  FAIL: flag left behind"; FAILS=$((FAILS+1)); } || echo "  ok: flag cleared"
dumpe2fs -h "$P3DEV" 2>/dev/null | awk '/^Block count:/ {print "  ok: FS blocks now " $3}'

echo
echo "== S6 filesystem already covers the partition: nothing to do"
reset_mbr
BC=$(dumpe2fs -h "$P3DEV" 2>/dev/null | awk '/^Block count:/ {print $3}')
BS=$(dumpe2fs -h "$P3DEV" 2>/dev/null | awk '/^Block size:/ {print $3}')
SZ=$((BC * BS / 512))
fake_p3 $((DISKSECT - SZ)) "$SZ"           # partition exactly as big as the FS
BEFORE=$(stat -c %Y "$T/p3.img")
run_grow
nocheck "growing"; nocheck "REBOOT-CALLED"; nocheck "creating CPZDATA"
AFTER=$(stat -c %Y "$T/p3.img")
[ "$BEFORE" = "$AFTER" ] && echo "  ok: partition untouched" || { echo "  FAIL: touched an already-grown CPZDATA"; FAILS=$((FAILS+1)); }

echo
echo "== S7 CPZDATA ends before the end of the card: extend + reboot"
# the MBR really has the small p3 entry — on a device sysfs and the table
# always agree, and sfdisk --delete fails on a missing entry
printf "16384,524288,c\n540672,3145728,83\n8388608,4194304,83\n" \
    | sfdisk --no-reread --no-tell-kernel --force "$DISK" >/dev/null 2>&1
rm -f "$T/pending"
fake_p3 "$P3START" 4194304      # 2 GiB, ends far before 8 GiB
attach_p3 2147483648; mkfs.ext4 -q -F -L CPZDATA "$T/p3.img" >/dev/null
P3DEV="$P3LOOP"
run_grow
check "extending CPZDATA"; check "REBOOT-CALLED"
[ "$(cat "$T/pending" 2>/dev/null)" = extend ] && echo "  ok: flag=extend" || { echo "  FAIL: flag not extend"; FAILS=$((FAILS+1)); }
assert_p3_at_card_end; assert_no_p4

echo
echo "== S8 foreign partition table: never touch it"
reset_mbr; fake_p3 none; attach_p3 1048576
BEFORE=$(od -An -tx1 -N 512 "$T/disk.img" | tr -d ' \n')
printf "99999\n" > "$T/sys/block/mmcblk0/mmcblk0p1/start"
run_grow
check "not a CPZ partition table"; nocheck "REBOOT-CALLED"
AFTER=$(od -An -tx1 -N 512 "$T/disk.img" | tr -d ' \n')
[ "$BEFORE" = "$AFTER" ] && echo "  ok: MBR untouched" || { echo "  FAIL: MBR rewritten"; FAILS=$((FAILS+1)); }
printf "16384\n" > "$T/sys/block/mmcblk0/mmcblk0p1/start"

echo
echo "== S9 card smaller than the 4 GiB offset: no persistence, no reboot"
reset_mbr; fake_p3 none; attach_p3 1048576
printf "4194304\n" > "$T/sys/block/mmcblk0/size"   # 2 GiB card
run_grow
check "card is smaller"; nocheck "REBOOT-CALLED"
printf "$DISKSECT\n" > "$T/sys/block/mmcblk0/size"

echo
echo "== S10 healthy grown card, every later boot: fully silent"
reset_mbr; attach_p3 4294967296; mkfs.ext4 -q -F -L CPZDATA "$T/p3.img" >/dev/null
P3DEV="$P3LOOP"
BC=$(dumpe2fs -h "$P3DEV" 2>/dev/null | awk '/^Block count:/ {print $3}')
BS=$(dumpe2fs -h "$P3DEV" 2>/dev/null | awk '/^Block size:/ {print $3}')
SZ=$((BC * BS / 512))
fake_p3 $((DISKSECT - SZ)) "$SZ"
run_grow
[ -z "$(cat "$T/out")" ] && echo "  ok: silent on a healthy card" || { echo "  FAIL: noise on a healthy card:"; cat "$T/out"; FAILS=$((FAILS+1)); }

detach "$DISK"; [ -n "$P3LOOP" ] && detach "$P3LOOP"

echo
if [ "$FAILS" -eq 0 ]; then
    echo "cpz-grow simulation: PASS"
    exit 0
fi
echo "cpz-grow simulation: $FAILS FAILURE(S)"
exit 1
