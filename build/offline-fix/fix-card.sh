#!/bin/sh
# build/offline-fix/fix-card.sh — patch an already-flashed CPZ-Alpine card so a
# machine with NO serial adapter can still get in and see what happened.
#
# Run as root on the host that has the card in a reader:
#     sudo sh fix-card.sh /dev/sdb
#
# What it changes on the card (idempotent, keeps .orig backups):
#   1. config.txt   : dtoverlay=dwc2,dr_mode=peripheral  (the [cm4]/[cm5]
#                     blocks in the stock config never match a CM0, so the
#                     USB port was left at whatever the DT default is)
#   2. /etc/modules : libcomposite + g_serial  -> /dev/ttyGS0
#   3. /etc/inittab : getty on ttyGS0 (waits for the gadget to bind)
#   4. /etc/cpz-early.sh + inittab sysinit hook: dumps the full kernel log to
#      the FAT partition as /boot/cpz-early.log DURING boot, so the log
#      survives even if userspace dies later
#   5. /etc/local.d/zz-dump.start: later snapshot -> /boot/cpz-late.log
#
# After this: set the device's USB switch to SLAVE, plug the right-hand
# USB-C into the computer, and a /dev/ttyACM* appears with a login prompt.
set -eu

# --- find the card safely: the CPZ root partition is labelled cpz-root and
# the boot partition CPZBOOT. Never guess a device name.
DEV=${1:-}
if [ -z "$DEV" ]; then
    for p in /dev/sd*[0-9] /dev/mmcblk*p[0-9] /dev/nvme*n*p[0-9]; do
        [ -b "$p" ] || continue
        if [ "$(blkid -s LABEL -o value "$p" 2>/dev/null)" = "CPZBOOT" ]; then
            DEV=${p%[0-9]}
            DEV=${DEV%p}          # mmcblk0p -> mmcblk0
            break
        fi
    done
fi
[ -n "$DEV" ] || { echo "No card labelled CPZBOOT found. Is it inserted?"; exit 1; }
echo "card: $DEV"
P1=${DEV}1
P2=${DEV}2
[ -b "$P1" ] || P1=${DEV}p1
[ -b "$P2" ] || P2=${DEV}p2
M1=/mnt/cpzboot
M2=/mnt/cpzroot

[ -b "$P1" ] || { echo "FAT partition $P1 not found"; exit 1; }
[ -b "$P2" ] || { echo "root partition $P2 not found"; exit 1; }

mkdir -p "$M1" "$M2"
umount "$M1" 2>/dev/null || true
umount "$M2" 2>/dev/null || true
mount "$P1" "$M1"
mount "$P2" "$M2"

echo "=========== what the card says so far ==========="
if [ -d "$M2/etc/dropbear" ]; then
    n=$(ls "$M2"/etc/dropbear/*host_key 2>/dev/null | wc -l)
    echo "dropbear host keys: $n  (3 = userspace reached the default runlevel)"
else
    echo "dropbear: no /etc/dropbear at all"
fi
tune2fs -l "$P2" 2>/dev/null | grep -E "Last mount time|Last write time|Mount count|Filesystem state" || true
echo "boot partition files: $(ls "$M1" | wc -l)"
echo "================================================="

# --- 1. USB peripheral mode ------------------------------------------------
cp -n "$M1/config.txt" "$M1/config.txt.orig" 2>/dev/null || true
if grep -q 'dtoverlay=dwc2,dr_mode=peripheral' "$M1/config.txt"; then
    echo "config.txt: dwc2 peripheral already present"
else
    cat >> "$M1/config.txt" <<'EOF'

# --- console over USB-C (debugging; CM0 never matched [cm4]/[cm5]) ---
[all]
dtoverlay=dwc2,dr_mode=peripheral
EOF
    echo "config.txt: added dwc2 dr_mode=peripheral"
fi

# --- 2. gadget modules -----------------------------------------------------
grep -q '^libcomposite' "$M2/etc/modules" 2>/dev/null || \
    printf 'libcomposite\ng_serial\n' >> "$M2/etc/modules"
echo "modules: $(grep -cE '^(libcomposite|g_serial)$' "$M2/etc/modules") gadget entries"

# --- 3. getty on the gadget ------------------------------------------------
cat > "$M2/etc/cpz-ttygs0.sh" <<'EOF'
#!/bin/sh
# wait for the USB CDC-ACM gadget to bind, then offer a login on it
while [ ! -c /dev/ttyGS0 ]; do sleep 2; done
exec /sbin/getty -L 115200 ttyGS0 vt100
EOF
chmod +x "$M2/etc/cpz-ttygs0.sh"
grep -q 'cpz-ttygs0' "$M2/etc/inittab" || \
    printf 'ttyGS0::respawn:/etc/cpz-ttygs0.sh\n' >> "$M2/etc/inittab"

# --- 4. early log dump to the FAT partition --------------------------------
cat > "$M2/etc/cpz-early.sh" <<'EOF'
#!/bin/sh
# Dump the kernel log onto the FAT boot partition during sysinit, before
# /boot is mounted and before networking: the log survives any later death.
mkdir -p /mnt/cpzboot
dev=""
for d in /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/sda1 /dev/sdb1; do
    [ -b "$d" ] && dev=$d && break
done
[ -n "$dev" ] || exit 0
mount -t vfat -o rw "$dev" /mnt/cpzboot 2>/dev/null || exit 0
{
    echo "=== cpz early boot dump ==="
    date 2>/dev/null
    echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
    printf 'model: '; cat /proc/device-tree/model 2>/dev/null; echo
    printf 'compatible: '; cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ' '; echo
    echo
    echo "=== dmesg ==="
    dmesg
    echo
    echo "=== framebuffers ==="
    ls -l /sys/class/graphics/ 2>/dev/null
    for f in /sys/class/graphics/fb*/name /sys/class/graphics/fb*/virtual_size \
             /sys/class/graphics/fb*/blank /sys/class/graphics/fb*/bits_per_pixel; do
        [ -e "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
    done
    echo
    echo "=== loaded modules ==="
    cat /proc/modules 2>/dev/null
} > /mnt/cpzboot/cpz-early.log 2>&1
sync
umount /mnt/cpzboot 2>/dev/null
EOF
chmod +x "$M2/etc/cpz-early.sh"
grep -q 'cpz-early' "$M2/etc/inittab" || \
    sed -i '/::sysinit:\/sbin\/openrc sysinit/a ::sysinit:/bin/sh /etc/cpz-early.sh' \
        "$M2/etc/inittab"

# --- 5. late snapshot ------------------------------------------------------
mkdir -p "$M2/etc/local.d"
cat > "$M2/etc/local.d/zz-dump.start" <<'EOF'
#!/bin/sh
{
    echo "=== cpz late boot dump ==="
    date
    echo "--- uname ---"; uname -a
    echo "--- lsmod ---"; lsmod
    echo "--- framebuffers ---"; ls -l /sys/class/graphics/ 2>/dev/null
    for f in /sys/class/graphics/fb*/name /sys/class/graphics/fb*/virtual_size \
             /sys/class/graphics/fb*/blank; do
        [ -e "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
    done
    echo "--- drm connectors ---"
    for c in /sys/class/drm/*/status; do echo "$c = $(cat "$c" 2>/dev/null)"; done
    echo "--- i2c buses ---"; ls /dev/i2c-* 2>/dev/null
    echo "--- input devices ---"; cat /proc/bus/input/devices 2>/dev/null
    echo "--- dmesg (tail 250) ---"; dmesg | tail -250
} > /boot/cpz-late.log 2>&1
EOF
chmod +x "$M2/etc/local.d/zz-dump.start"

sync
umount "$M1" "$M2"
echo
echo "PATCHED. Set the device USB switch to SLAVE, plug the right USB-C into"
echo "this computer, power on, then:  ls /dev/ttyACM*  &&  picocom -b 115200 /dev/ttyACM0"