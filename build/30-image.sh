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
VER=0.18.3
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
# Wi-Fi credentials injection (v0.10; v0.17 — NetworkManager keyfile):
# build/wifi-secret/ is NOT part of the repo — it holds this user's
# wpa_supplicant.conf, fetched from the device. When present, the SSID
# and PSK are converted into an NM keyfile profile (the standalone
# supplicant service no longer runs; NM spawns its own) so every built
# image carries the credentials and reflashes never lose the network.
# A missing secret ships no profile — Wi-Fi is then joined on-device
# through the launcher's Settings → Wi-Fi UI (which writes the same
# keyfile directory).
SSID=$(sed -n 's/^[[:space:]]*ssid="//;s/"[[:space:]]*$//p' \
    $REPO/build/wifi-secret/wpa_supplicant.conf 2>/dev/null | head -1)
[ -z "$SSID" ] && SSID=$(sed -n 's/^[[:space:]]*ssid=//p' \
    $REPO/build/wifi-secret/wpa_supplicant.conf 2>/dev/null | head -1 | tr -d '[:space:]')
PSK=$(sed -n 's/^[[:space:]]*psk="//;s/"[[:space:]]*$//p' \
    $REPO/build/wifi-secret/wpa_supplicant.conf 2>/dev/null | head -1)
[ -z "$PSK" ] && PSK=$(sed -n 's/^[[:space:]]*psk=//p' \
    $REPO/build/wifi-secret/wpa_supplicant.conf 2>/dev/null | head -1 | tr -d '[:space:]')
if [ -n "$SSID" ] && [ -n "$PSK" ]; then
    mkdir -p -m 0700 /mnt/rootfs/etc/NetworkManager/system-connections
    printf '[connection]\nid=cpz-wifi\ntype=wifi\nautoconnect=true\n\n[wifi]\nssid=%s\nmode=infrastructure\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
        "$SSID" "$PSK" \
        > /mnt/rootfs/etc/NetworkManager/system-connections/cpz-wifi.nmconnection
    chmod 0600 /mnt/rootfs/etc/NetworkManager/system-connections/cpz-wifi.nmconnection
    echo "== wifi credentials injected as NM keyfile (build/wifi-secret) =="
else
    echo "== no build/wifi-secret/ — Wi-Fi joins on-device via launcher Settings =="
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
    # v0.2..v0.16 history: fbcon was mapped onto the panel (map:1) to give
    # the LCD a login console. v0.17: the panel is owned by the APPLaunch
    # launcher UI (OpenRC `applaunch`, draws directly to the fbtft fb);
    # the kernel console lives on HDMI like the stock M5 image. A shared
    # fb would have kernel writes scribbling over the UI — never map
    # fbcon back onto the panel.
    grep -q 'fbcon=map:0' /mnt/boot/cmdline.txt \
        && echo "OK: fbcon=map:0 (console on HDMI; panel owned by launcher)" \
        || echo "FAIL: fbcon map is not 0 — console would fight the launcher"
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
    # v0.17: NetworkManager owns wlan0/eth0; the ifupdown file must NOT
    # claim devices (a listed device would fight NM for the interface).
    grep -q "^auto lo$" /mnt/rootfs/etc/network/interfaces \
        && grep -qv "^auto wlan0\|^auto eth0" /mnt/rootfs/etc/network/interfaces \
        && echo "OK: interfaces is lo-only (NetworkManager owns devices)" \
        || echo "FAIL: interfaces still claims wlan0/eth0"
    # baked Wi-Fi is an NM keyfile now; absent secret = joined on device
    NMKEY=/mnt/rootfs/etc/NetworkManager/system-connections/cpz-wifi.nmconnection
    if [ -s "$NMKEY" ]; then
        grep -q "^ssid=" "$NMKEY" && grep -q "^psk=" "$NMKEY" \
            && echo "OK: wifi credentials baked as NM keyfile" \
            || echo "FAIL: NM keyfile missing ssid/psk"
        [ "$(stat -c %a "$NMKEY")" = "600" ] \
            && echo "OK: NM keyfile is 0600" \
            || echo "FAIL: NM keyfile permissions not 0600"
    else
        echo "OK: no baked wifi — join via launcher Settings → Wi-Fi"
    fi
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
    # v0.14: on-demand HDMI desktop (docs/05, Gate G3 — field-verified:
    # sway+foot up in ~5s, ~57 MiB resident, clean stop)
    [ -x /mnt/rootfs/usr/bin/sway ] \
        && echo "OK: sway installed" \
        || echo "FAIL: sway missing"
    [ -x /mnt/rootfs/usr/bin/foot ] \
        && echo "OK: foot terminal installed" \
        || echo "FAIL: foot missing"
    # v0.15: the light desktop — bar + launcher + session dbus
    [ -x /mnt/rootfs/usr/bin/waybar ] \
        && echo "OK: waybar (status bar) installed" \
        || echo "FAIL: waybar missing"
    [ -x /mnt/rootfs/usr/bin/bemenu-run ] \
        && echo "OK: bemenu (app launcher) installed" \
        || echo "FAIL: bemenu missing"
    grep -q "dbus-run-session sway" /mnt/rootfs/usr/local/bin/cpz-desktop \
        && echo "OK: session wrapped in dbus-run-session (GTK apps live)" \
        || echo "FAIL: no session dbus — waybar dies on autolaunch"
    grep -q "exec waybar" /mnt/rootfs/etc/cpz/sway.config \
        && echo "OK: bar autostarts in session" \
        || echo "FAIL: waybar not in session config"
    grep -q "bemenu-run" /mnt/rootfs/etc/cpz/sway.config \
        && echo "OK: launcher bound in session config" \
        || echo "FAIL: no launcher binding"
    [ -x /mnt/rootfs/usr/local/bin/cpz-desktop ] \
        && echo "OK: cpz-desktop launcher present" \
        || echo "FAIL: cpz-desktop missing"
    # v0.17.2 field fixes: Alpine splits NM's wifi support + CLI out of the
    # main package. Without them nmcli is absent and NM marks wlan0
    # unmanaged ("device type unmanaged by default") — the launcher's
    # Wi-Fi toggle then does nothing.
    [ -x /mnt/rootfs/usr/bin/nmcli ] \
        && echo "OK: nmcli (NetworkManager CLI) installed" \
        || echo "FAIL: nmcli missing — Wi-Fi/Ethernet settings dead"
    ls /mnt/rootfs/usr/lib/NetworkManager/*/libnm-device-plugin-wifi.so \
        >/dev/null 2>&1 \
        && echo "OK: NetworkManager wifi device plugin installed" \
        || echo "FAIL: NM wifi plugin missing — wlan0 stays unmanaged"
    # Alpine installs wpa_supplicant under /sbin (not /usr/sbin).
    if [ -x /mnt/rootfs/sbin/wpa_supplicant ] || [ -x /mnt/rootfs/usr/sbin/wpa_supplicant ]; then
        echo "OK: wpa_supplicant (NM wifi backend) installed"
    else
        echo "FAIL: wpa_supplicant missing — NM cannot associate"
    fi
    # v0.17.2: the cpz session user must be able to read the desktop config
    # (0600 root-only made sway die with "Unable to open sway.config").
    for f in /mnt/rootfs/etc/cpz/sway.config /mnt/rootfs/etc/cpz/hdmi-mode; do
        [ -n "$(find "$f" -perm -004 2>/dev/null)" ] \
            && echo "OK: $(basename "$f") readable by the session user" \
            || echo "FAIL: $(basename "$f") not world-readable — desktop session dies"
    done
    # v0.17.2: cpz-desktop waits for the seatd socket and forces the seatd
    # libseat backend (logind is absent; without this sway fails to start).
    grep -q '/run/seatd.sock' /mnt/rootfs/usr/local/bin/cpz-desktop \
        && grep -q 'LIBSEAT_BACKEND=seatd' /mnt/rootfs/usr/local/bin/cpz-desktop \
        && echo "OK: cpz-desktop waits for seatd + forces seatd backend" \
        || echo "FAIL: cpz-desktop lacks the seatd readiness/backend fix"
    [ -s /mnt/rootfs/etc/cpz/sway.config ] \
        && echo "OK: session config present" \
        || echo "FAIL: no sway.config"
    [ -s /mnt/rootfs/etc/cpz/hdmi-mode ] \
        && echo "OK: hotplug consent mode file present" \
        || echo "FAIL: no /etc/cpz/hdmi-mode"
    [ -s /mnt/rootfs/etc/udev/rules.d/99-cpz-hdmi.rules ] \
        && echo "OK: HDMI hotplug udev rule present" \
        || echo "FAIL: no udev hotplug rule"
    # v0.14.1: internal keypad on seat0 — without this, sway's session
    # never receives the keyboard (M5's rule exiles it to a private seat
    # for their dual-session launcher; verified live: sway inputs lacked
    # tca8418c until ID_SEAT was overridden)
    grep -q 'ID_SEAT}="seat0"' /mnt/rootfs/etc/udev/rules.d/99-cpz-input-seat.rules \
        && echo "OK: internal keypad assigned to seat0 (desktop input works)" \
        || echo "FAIL: keypad stuck on M5 private seat — dead keys in sway"
    # the on-demand contract: NOTHING graphical in any runlevel
    if ls /mnt/rootfs/etc/runlevels/*/seatd >/dev/null 2>&1; then
        echo "FAIL: seatd is in a boot runlevel — violates the on-demand contract"
    else
        echo "OK: seatd not in any runlevel (on-demand contract holds)"
    fi
    # v0.17: APPLaunch launcher — the UI that owns the internal LCD.
    # Built natively (musl aarch64) by build/25-launcher.sh from the
    # launcher/ checkout (alpine branch), installed at /usr/share/APPLaunch
    # and started by OpenRC as the root user.
    [ -x /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch ] \
        && echo "OK: launcher binary present" \
        || echo "FAIL: launcher binary missing"
    # v0.17.2: the volume path falls back to amixer when libpulse is absent
    # (no pipewire-pulse on this image); the strings prove the fallback made
    # it into the shipped binary.
    grep -aq "amixer" /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch \
        && echo "OK: launcher carries the ALSA volume fallback (amixer)" \
        || echo "FAIL: launcher binary has no ALSA volume fallback"
    [ -x /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-Calculator ] \
        && echo "OK: calculator binary present" \
        || echo "FAIL: calculator binary missing"
    [ -d /mnt/rootfs/usr/share/APPLaunch/share/images ] \
        && echo "OK: launcher resource tree present" \
        || echo "FAIL: launcher resource tree missing"
    [ -d /mnt/rootfs/usr/share/APPLaunch/applications ] \
        && echo "OK: launcher .desktop dir present" \
        || echo "FAIL: launcher applications dir missing"
    [ -x /mnt/rootfs/etc/init.d/applaunch ] \
        && echo "OK: applaunch OpenRC init script present" \
        || echo "FAIL: applaunch init script missing"
    [ -L /mnt/rootfs/etc/runlevels/default/applaunch ] \
        && echo "OK: applaunch service in default runlevel" \
        || echo "FAIL: applaunch service not enabled"
    grep -q "command=\"/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch\"" \
        /mnt/rootfs/etc/init.d/applaunch \
        && echo "OK: applaunch runs the installed binary" \
        || echo "FAIL: applaunch command path wrong"
    # launcher runtime link set (musl) + CLI terminal shell
    [ -e /mnt/rootfs/usr/lib/libfreetype.so.6 ] \
        && echo "OK: freetype (launcher) installed" \
        || echo "FAIL: freetype missing"
    [ -e /mnt/rootfs/usr/lib/libinput.so.10 ] \
        && echo "OK: libinput (keypad) installed" \
        || echo "FAIL: libinput missing"
    [ -e /mnt/rootfs/usr/lib/libgio-2.0.so.0 ] \
        && echo "OK: glib/gio (NetworkManager dbus) installed" \
        || echo "FAIL: glib missing"
    [ -x /mnt/rootfs/bin/bash ] \
        && echo "OK: bash (launcher CLI terminal) installed" \
        || echo "FAIL: bash missing — launcher CLI terminal dead"
    # v0.17: NetworkManager replaced ifupdown-ng/wpa_supplicant boot path
    [ -x /mnt/rootfs/usr/sbin/NetworkManager ] \
        && echo "OK: NetworkManager installed" \
        || echo "FAIL: NetworkManager missing"
    [ -L /mnt/rootfs/etc/runlevels/default/networkmanager ] \
        && echo "OK: networkmanager service in default runlevel" \
        || echo "FAIL: networkmanager service not enabled"
    [ -L /mnt/rootfs/etc/runlevels/default/dbus ] \
        && echo "OK: dbus service in default runlevel" \
        || echo "FAIL: dbus service not enabled"
    if [ -e /mnt/rootfs/etc/runlevels/boot/networking ] \
        || [ -e /mnt/rootfs/etc/runlevels/boot/wpa_supplicant ]; then
        echo "FAIL: ifupdown/wpa service still enabled — two managers fight over wlan0"
    else
        echo "OK: no ifupdown/wpa service (NetworkManager alone owns the interfaces)"
    fi
    # launcher runtime keymap for the SYM layer (keycap-corrected; the
    # launcher's evdev path parses this file, the console uses
    # cpz-sym-keymap.map with the same measurements)
    [ -s /mnt/rootfs/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map ] \
        && grep -q "^keycode 216 = slash" \
            /mnt/rootfs/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map \
        && echo "OK: launcher SYM keymap (keycap-corrected) shipped" \
        || echo "FAIL: launcher SYM keymap missing or wrong"
    # launcher state dir (settings.json/config.json) — init script recreates,
    # but the image must ship it for first boot
    [ -d /mnt/rootfs/var/lib/applaunch ] \
        && echo "OK: /var/lib/applaunch state dir present" \
        || echo "FAIL: /var/lib/applaunch missing"
    # v0.18.0: the launcher runs as cpz with passwordless sudo + hardware
    # groups; the HDMI desktop stays dark until started.
    [ -x /mnt/rootfs/usr/bin/sudo ] \
        && echo "OK: sudo installed (cpz escalation)" \
        || echo "FAIL: sudo missing"
    [ -f /mnt/rootfs/etc/sudoers.d/cpz ] \
        && [ "$(stat -c %a /mnt/rootfs/etc/sudoers.d/cpz)" = "440" ] \
        && echo "OK: /etc/sudoers.d/cpz present (0440, NOPASSWD)" \
        || echo "FAIL: cpz sudoers file missing or wrong mode"
    grep -q 'command_user="cpz:cpz"' /mnt/rootfs/etc/init.d/applaunch \
        && echo "OK: applaunch runs as user cpz" \
        || echo "FAIL: applaunch still runs as root"
    # v0.18.1: start-stop-daemon drops to cpz before opening the log, so
    # the log must be cpz-writable or the service dies without exec.
    grep -q 'chown cpz:cpz /var/log/applaunch.log' /mnt/rootfs/etc/init.d/applaunch \
        && echo "OK: applaunch log writable by cpz (service can open it)" \
        || echo "FAIL: applaunch log still root-only — service dies before exec"
    # The builder cannot resolve image usernames (no cpz in its passwd),
    # so compare the numeric uid from the image's own passwd entry.
    CPZ_UID=$(awk -F: '$1 == "cpz" { print $3 }' /mnt/rootfs/etc/passwd)
    [ -n "$CPZ_UID" ] && [ "$(stat -c %u /mnt/rootfs/var/lib/applaunch)" = "$CPZ_UID" ] \
        && echo "OK: /var/lib/applaunch owned by cpz" \
        || echo "FAIL: /var/lib/applaunch not writable by cpz"
    for g in video input audio i2c seat; do
        grep -q "^$g:.*\bcpz\b" /mnt/rootfs/etc/group \
            && echo "OK: cpz in group $g" \
            || echo "FAIL: cpz missing from group $g"
    done
    [ -s /mnt/rootfs/etc/udev/rules.d/99-cpz-device-groups.rules ] \
        && echo "OK: i2c/rtc/audio udev group rules present" \
        || echo "FAIL: device group udev rules missing"
    # HDMI stays dark: no VT getty, no tty1 kernel console, no splash
    if grep -qE "^tty(1|2)::respawn" /mnt/rootfs/etc/inittab; then
        echo "FAIL: a VT getty is enabled — it would paint HDMI at boot"
    else
        echo "OK: no VT getty (HDMI stays dark until the desktop starts)"
    fi
    grep -q "console=tty1" /mnt/boot/cmdline.txt \
        && echo "FAIL: kernel console still mapped to tty1 (HDMI output)" \
        || echo "OK: kernel console serial-only (no HDMI boot text)"
    grep -q "disable_splash=1" /mnt/boot/config.txt \
        && echo "OK: firmware splash disabled" \
        || echo "FAIL: firmware splash still enabled"
    [ -x /mnt/rootfs/etc/local.d/cpz-hdmi-boot.start ] \
        && echo "OK: HDMI desktop preference re-applied at boot" \
        || echo "FAIL: cpz-hdmi-boot.start missing"
    grep -q "chown -R cpz:cpz /var/lib/applaunch" /mnt/rootfs/etc/local.d/cpz-restore.start \
        && echo "OK: restored launcher state re-owned to cpz" \
        || echo "FAIL: restore leaves cpz state root-owned"
    grep -q "as_root" /mnt/rootfs/usr/local/bin/cpz-desktop \
        && echo "OK: cpz-desktop works for cpz (sudo escalation)" \
        || echo "FAIL: cpz-desktop only works as root"
    # launcher assets: Alpine lock-screen wallpaper + HDMI app icon + page
    # v0.18.1: the Alpine artwork replaced the stock lockscreen.png
    # (320x150, drawn under the lock clock); the home screen keeps its
    # stock background. Compare against the repo asset so a stale image
    # asset fails the build.
    LOCK_REPO=/repo/launcher/projects/APPLaunch/APPLaunch/share/images/lockscreen.png
    if [ -s /mnt/rootfs/usr/share/APPLaunch/share/images/lockscreen.png ] &&
       [ "$(stat -c %s /mnt/rootfs/usr/share/APPLaunch/share/images/lockscreen.png)" = \
         "$(stat -c %s "$LOCK_REPO" 2>/dev/null)" ]; then
        echo "OK: Alpine lock-screen wallpaper shipped"
    else
        echo "FAIL: lockscreen.png is not the Alpine artwork"
    fi
    [ -e /mnt/rootfs/usr/share/APPLaunch/share/images/alpine_wallpaper.png ] \
        && echo "FAIL: home wallpaper asset should not ship (belongs on the lock screen)" \
        || echo "OK: home screen has no custom wallpaper"
    [ -s /mnt/rootfs/usr/share/APPLaunch/share/images/hdmi_100.png ] \
        && echo "OK: HDMI app icon shipped" \
        || echo "FAIL: hdmi_100.png missing"
    grep -aq "hdmi-desktop" /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch \
        && echo "OK: launcher carries the HDMI desktop app" \
        || echo "FAIL: HDMI app not compiled into the launcher"
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
