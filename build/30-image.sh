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
VER=0.21.12
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
    # v0.21.3: optional Tailscale app. The daemon/package is NOT in the
    # image (it is an on-device apk install), so only the launcher-side
    # plumbing can be checked here: the root helper, the boot hook and the
    # persistence members that keep the node logged in across a reflash.
    [ -x /mnt/rootfs/usr/local/bin/cpz-tailscale ] \
        && echo "OK: cpz-tailscale helper present" \
        || echo "FAIL: cpz-tailscale missing — Tailscale app cannot toggle"
    [ -x /mnt/rootfs/etc/local.d/cpz-tailscale-boot.start ] \
        && echo "OK: Tailscale boot hook present" \
        || echo "FAIL: cpz-tailscale-boot.start missing — ON/OFF not re-applied"
    grep -q 'var/lib/tailscale' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: Tailscale node state saved to /cfg" \
        || echo "FAIL: cpz-save does not archive /var/lib/tailscale"
    grep -q 'var/lib/tailscale' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: Tailscale node state restored from /cfg" \
        || echo "FAIL: cpz-restore does not merge /var/lib/tailscale"
    [ -s /mnt/rootfs/usr/share/APPLaunch/share/images/tailscale_100.png ] \
        && echo "OK: Tailscale app icon installed" \
        || echo "FAIL: tailscale_100.png missing from the launcher resources"
    # v0.21.4: the launcher state dir must not be archive-wins on a normal
    # boot (it made an OFF Tailscale switch come back ON). The guard is a
    # named variable so a future refactor cannot silently drop it.
    grep -q 'LAUNCHER_LIVE' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: launcher state kept live across a normal boot" \
        || echo "FAIL: cpz-restore still restores /var/lib/applaunch unconditionally"
    # v0.17.2 field fixes: Alpine splits NM's wifi support + CLI out of the
    # main package. Without them nmcli is absent and NM marks wlan0
    # unmanaged ("device type unmanaged by default") — the launcher's
    # Wi-Fi toggle then does nothing.
    # v0.19.1: NetworkManager has no polkit on Alpine; cpz gets "Not authorized".
    # Every launcher nmcli call goes through this passwordless-sudo wrapper.
    [ -x /mnt/rootfs/usr/local/bin/cpz-nmcli ] \
        && grep -aq '/usr/local/bin/cpz-nmcli' /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch \
        && echo "OK: launcher nmcli goes through cpz-nmcli (root; NM auth)" \
        || echo "FAIL: cpz-nmcli wrapper missing or launcher still calls nmcli directly"

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
    # v0.19.0: the launcher runs as cpz, so a 0600 keymap is unreadable and
    # the launcher silently falls back to the stale stock table.
    [ "$(stat -c %a /mnt/rootfs/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map 2>/dev/null)" = "644" ] \
        && echo "OK: launcher SYM keymap readable by cpz (0644)" \
        || echo "FAIL: launcher SYM keymap not 0644 — cpz falls back to stale map"
    # v0.19.0: internal-keypad XKB sym option + Super remap.
    [ -s /mnt/rootfs/usr/share/X11/xkb/symbols/cpz ] \
        && grep -q 'xkb_symbols "sym"' /mnt/rootfs/usr/share/X11/xkb/symbols/cpz \
        && grep -q 'replace key <FK13>' /mnt/rootfs/usr/share/X11/xkb/symbols/cpz \
        && grep -q 'replace key <LVL5>' /mnt/rootfs/usr/share/X11/xkb/symbols/cpz \
        && grep -q 'include "us(basic)"' /mnt/rootfs/usr/share/X11/xkb/symbols/cpz \
        && echo "OK: cpz XKB sym option shipped (FK13.. + LVL5..)" \
        || echo "FAIL: cpz XKB sym option missing or wrong"
    if grep -q 'cpz:sym' /mnt/rootfs/usr/share/X11/xkb/rules/evdev 2>/dev/null \
        || grep -q 'cpz:sym' /mnt/rootfs/usr/share/xkeyboard-config-2/rules/evdev 2>/dev/null; then
        echo "OK: cpz:sym mapped in XKB rules"
    else
        echo "FAIL: cpz:sym missing from XKB rules"
    fi
    grep -Fq 'xkb_options "cpz:sym,altwin:swap_lalt_lwin"' /mnt/rootfs/etc/cpz/sway.config \
        && grep -q 'XKB_DEFAULT_OPTIONS=cpz:sym' /mnt/rootfs/usr/local/bin/cpz-desktop \
        && echo "OK: seat default and internal keyboard load cpz:sym (comma-separated with altwin)" \
        || echo "FAIL: sway/desktop missing cpz:sym default or comma-separated internal options"
    grep -q 'cpz-desktop stop' /mnt/rootfs/etc/cpz/sway.config \
        && echo "OK: Mod+Shift+E stops the desktop (LCD unlock path)" \
        || echo "FAIL: sway exit binding does not stop the desktop"
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
    # v0.21.1: Alpine's busybox is not setuid, so its `passwd` applet says
    # "must be suid to work properly" when cpz runs it. The shadow package
    # replaces the /usr/bin/passwd symlink with a 4755 root:root binary.
    [ ! -L /mnt/rootfs/usr/bin/passwd ] \
        && [ "$(stat -c %a /mnt/rootfs/usr/bin/passwd)" = "4755" ] \
        && [ "$(stat -c %u:%g /mnt/rootfs/usr/bin/passwd)" = "0:0" ] \
        && echo "OK: passwd is setuid root (shadow, not the busybox symlink)" \
        || echo "FAIL: passwd is not setuid root — cpz cannot change its password"
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
    grep -q "chown -R cpz:cpz /var/lib/applaunch" /mnt/rootfs/etc/cpz-restore.start \
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
    # v0.20.0: Files and Camera are default launcher apps. Both are built
    # natively (aarch64/musl) by build/26-apps.sh; Camera is pinned to the
    # 1.0.2 ABI because Alpine 3.24 ships libcamera 0.7.1.
    for app in M5CardputerZero-Files camera_app; do
        bin="/mnt/rootfs/usr/share/APPLaunch/bin/$app"
        [ -x "$bin" ] \
            && echo "OK: $app binary present" \
            || echo "FAIL: $app binary missing"
        file "$bin" | grep -q 'ARM aarch64' \
            && file "$bin" | grep -q 'interpreter /lib/ld-musl-aarch64' \
            && echo "OK: $app is a musl aarch64 binary" \
            || echo "FAIL: $app is not a musl aarch64 binary"
    done
    [ -x /mnt/rootfs/usr/local/bin/cpz-files ] \
        && grep -q 'FILES_START_DIR=${FILES_START_DIR:-$HOME}' \
            /mnt/rootfs/usr/local/bin/cpz-files \
        && echo "OK: Files wrapper starts in the persisted /home/cpz tree" \
        || echo "FAIL: cpz-files wrapper missing or does not default to HOME"
    for f in files.desktop camera_app.desktop; do
        [ -s "/mnt/rootfs/usr/share/APPLaunch/applications/$f" ] \
            && echo "OK: $f launcher entry present" \
            || echo "FAIL: $f launcher entry missing"
    done
    grep -q '^Name=Files' /mnt/rootfs/usr/share/APPLaunch/applications/files.desktop \
        && grep -q '^Exec=/usr/local/bin/cpz-files' \
            /mnt/rootfs/usr/share/APPLaunch/applications/files.desktop \
        && echo "OK: Files entry points at cpz-files" \
        || echo "FAIL: Files .desktop entry wrong"
    grep -q '^Name=Camera' /mnt/rootfs/usr/share/APPLaunch/applications/camera_app.desktop \
        && grep -q '^Exec=/usr/share/APPLaunch/bin/camera_app' \
            /mnt/rootfs/usr/share/APPLaunch/applications/camera_app.desktop \
        && echo "OK: Camera entry points at the installed binary" \
        || echo "FAIL: Camera .desktop entry wrong"
    [ -s /mnt/rootfs/usr/share/APPLaunch/share/images/files.png ] \
        && [ -s /mnt/rootfs/usr/share/APPLaunch/share/images/camera1.png ] \
        && echo "OK: Files/Camera icons present" \
        || echo "FAIL: Files/Camera icons missing"
    grep -q '^files.desktop' /mnt/rootfs/usr/share/APPLaunch/preinstalled-desktop-apps.tsv \
        && grep -q '^camera_app.desktop' /mnt/rootfs/usr/share/APPLaunch/preinstalled-desktop-apps.tsv \
        && echo "OK: Files/Camera are preinstalled (enabled by default)" \
        || echo "FAIL: Files/Camera missing from the preinstalled manifest"
    [ -s /mnt/rootfs/usr/share/camera_app/fonts/camera_icons.ttf ] \
        && [ -s /mnt/rootfs/usr/share/camera_app/audio/shutter.wav ] \
        && echo "OK: Camera runtime fonts/audio installed" \
        || echo "FAIL: Camera asset tree incomplete"
    [ -s /mnt/rootfs/usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml ] \
        && echo "OK: rpicam-apps pipeline config installed" \
        || echo "FAIL: rpi_apps.yaml missing — Camera refuses to start"
    [ -s /mnt/rootfs/usr/share/libcamera/ipa/rpi/vc4/imx219.json ] \
        && [ -x /mnt/rootfs/usr/libexec/libcamera/raspberrypi_ipa_proxy ] \
        && echo "OK: Raspberry Pi libcamera IPA tuning + proxy installed" \
        || echo "FAIL: libcamera-raspberrypi IPA files missing"
    grep -q 'SUBSYSTEM=="dma_heap"' \
        /mnt/rootfs/etc/udev/rules.d/99-cpz-device-groups.rules \
        && echo "OK: dma-heap nodes are video-group accessible" \
        || echo "FAIL: no dma_heap udev rule (Camera gets EACCES)"
    [ -x /mnt/rootfs/usr/bin/ffmpeg ] \
        && echo "OK: ffmpeg installed (Files video preview)" \
        || echo "FAIL: ffmpeg missing — Files video preview dead"
    for lib in 'libcamera.so.*' 'libv4l2.so.*' 'libcjson.so.*' 'libfmt.so.*'; do
        ls /mnt/rootfs/usr/lib/$lib >/dev/null 2>&1 \
            && echo "OK: runtime $lib" \
            || echo "FAIL: runtime $lib missing (Camera link)"
    done
    # Files/Camera content lives under /home/cpz; cpz-save must keep that
    # tree in the /cfg snapshot and cpz-restore must merge it back.
    [ -d /mnt/rootfs/home/cpz ] \
        && [ -d /mnt/rootfs/home/cpz/Pictures/DCIM/Camera ] \
        && [ -d /mnt/rootfs/home/cpz/Videos/Camera ] \
        && echo "OK: Files/Camera content directories exist" \
        || echo "FAIL: Files/Camera content directories missing"
    grep -q 'home/cpz' /mnt/rootfs/usr/local/bin/cpz-save \
        && grep -q 'home/cpz' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: Files/Camera home tree is saved to /cfg and restored" \
        || echo "FAIL: home/cpz missing from persistence save/restore"
    # v0.11: persistence layer
    [ -d /mnt/rootfs/cfg ] \
        && echo "OK: /cfg mountpoint exists" \
        || echo "FAIL: no /cfg dir — persistence layer broken"
    [ -x /mnt/rootfs/usr/local/bin/cpz-save ] \
        && echo "OK: cpz-save present" \
        || echo "FAIL: cpz-save missing"
    [ -x /mnt/rootfs/etc/cpz-restore.start ] \
        && echo "OK: cpz-restore runs at boot" \
        || echo "FAIL: cpz-restore.start missing (boot service broke)"
    [ -x /mnt/rootfs/etc/init.d/cpz-restore ] \
        && echo "OK: cpz-restore init script present" \
        || echo "FAIL: /etc/init.d/cpz-restore missing"
    [ -L /mnt/rootfs/etc/runlevels/boot/cpz-restore ] \
        && echo "OK: cpz-restore in boot runlevel (before services)" \
        || echo "FAIL: cpz-restore not in boot runlevel"
    [ ! -e /mnt/rootfs/etc/local.d/cpz-restore.start ] \
        && echo "OK: restore no longer runs after the launcher" \
        || echo "FAIL: cpz-restore still in local.d (runs after applaunch)"
    [ -x /mnt/rootfs/etc/periodic/hourly/cpz-save ] \
        && echo "OK: hourly snapshots scheduled" \
        || echo "FAIL: no hourly cpz-save cron job"
    grep -q "run-parts" /mnt/rootfs/etc/crontabs/root \
        && echo "OK: crond periodic table configured" \
        || echo "FAIL: /etc/crontabs/root missing (crond idle, no snapshots)"
    # v0.21.6: persistence must keep up with a setup session. The 5-minute
    # cron, the NetworkManager connect hook and the shutdown hook are the
    # three triggers that stop "setup then reflash" from losing everything.
    grep -q '^\*/5.*cpz-save' /mnt/rootfs/etc/crontabs/root \
        && echo "OK: 5-minute cpz-save cron configured" \
        || echo "FAIL: no 5-minute cpz-save entry (hourly-only persistence)"
    [ -x /mnt/rootfs/etc/NetworkManager/dispatcher.d/90-cpz-save ] \
        && echo "OK: cpz-save runs on NetworkManager connect" \
        || echo "FAIL: NM dispatcher cpz-save missing"
    [ -x /mnt/rootfs/etc/local.d/cpz-save.stop ] \
        && echo "OK: cpz-save runs at shutdown" \
        || echo "FAIL: shutdown cpz-save hook missing"
    grep -q 'cpz-save.lock' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: cpz-save serialized (lock)" \
        || echo "FAIL: cpz-save has no lock — triggers can race"
    # v0.21.7/v0.21.8: save the moment a config path changes (card pulled /
    # power cut before the next tick), keep the previous archive, and leave
    # a restore trace on /cfg. v0.21.8 swapped the 5 s `stat` poll for
    # event-driven busybox inotifyd plus a 60 s poll fallback.
    [ -x /mnt/rootfs/usr/local/bin/cpz-state-watch ] \
        && echo "OK: config change watcher present" \
        || echo "FAIL: cpz-state-watch missing"
    [ -x /mnt/rootfs/usr/local/bin/cpz-state-watch-handler ] \
        && echo "OK: inotifyd handler present" \
        || echo "FAIL: cpz-state-watch-handler missing"
    [ -x /mnt/rootfs/etc/local.d/cpz-state-watch.start ] \
        && echo "OK: watcher starts at boot" \
        || echo "FAIL: cpz-state-watch.start missing"
    grep -q 'inotifyd' /mnt/rootfs/usr/local/bin/cpz-state-watch \
        && echo "OK: watcher is event-driven (inotifyd)" \
        || echo "FAIL: watcher is not inotifyd-based"
    grep -q 'INOTIFY_FALLBACK' /mnt/rootfs/usr/local/bin/cpz-state-watch \
        && echo "OK: watcher has a poll fallback for lost watches" \
        || echo "FAIL: watcher has no fallback for inotify overflow"
    grep -q 'sleep 60' /mnt/rootfs/usr/local/bin/cpz-state-watch \
        && echo "OK: watcher fallback polls at 60 s (not 5 s)" \
        || echo "FAIL: watcher fallback interval wrong"
    grep -q 'cpz-state-watch save' /mnt/rootfs/etc/local.d/cpz-state-watch.start \
        && grep -q 'cpz-state-watch dir' /mnt/rootfs/etc/local.d/cpz-state-watch.start \
        && grep -q 'INOTIFY_FALLBACK=1' /mnt/rootfs/etc/local.d/cpz-state-watch.start \
        && echo "OK: boot starts file, dir and fallback watchers" \
        || echo "FAIL: boot hook does not start all three watchers"
    grep -q 'save.tar.gz.prev' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: previous archive generation kept" \
        || echo "FAIL: cpz-save does not keep save.tar.gz.prev"
    grep -q 'cpz-restore.log' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: restore leaves a trace on /cfg" \
        || echo "FAIL: no restore trace (failures undiagnosable)"
    # v0.21.9: Settings fixes — writable backlight, saved volume at boot,
    # NTP on OpenRC.
    [ -x /mnt/rootfs/etc/local.d/cpz-permissions.start ] \
        && echo "OK: backlight permissions hook present" \
        || echo "FAIL: cpz-permissions.start missing (brightness writes fail)"
    grep -q '"volume"' /mnt/rootfs/etc/local.d/cpz-audio.start \
        && echo "OK: saved speaker volume applied at boot" \
        || echo "FAIL: cpz-audio.start ignores the saved volume"
    [ -x /mnt/rootfs/usr/local/bin/cpz-ntp ] \
        && echo "OK: NTP helper present" \
        || echo "FAIL: cpz-ntp missing (network time unavailable)"
    [ -x /mnt/rootfs/etc/local.d/zz-cpz-ntp.start ] \
        && echo "OK: NTP boot hook present" \
        || echo "FAIL: cpz-ntp.start missing"
    # v0.21.10: explicit package list + boot install status + launcher toast.
    grep -q 'CFG/world' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: /cfg/world saved" \
        || echo "FAIL: cpz-save does not save /cfg/world"
    grep -q 'cpz-pkg.status' /mnt/rootfs/etc/local.d/cpz-wifi.start \
        && echo "OK: package install status file written" \
        || echo "FAIL: no package install status"
    grep -q 'MISSING' /mnt/rootfs/etc/local.d/cpz-wifi.start \
        && echo "OK: only missing packages are installed (not the whole world)" \
        || echo "FAIL: boot install still adds the whole world"
    [ -x /mnt/rootfs/usr/local/bin/cpz-apk ] \
        && echo "OK: local .apk helper present" \
        || echo "FAIL: cpz-apk missing"
    grep -q 'cfg/apk' /mnt/rootfs/etc/local.d/cpz-wifi.start \
        && echo "OK: local .apk files reinstalled at boot" \
        || echo "FAIL: /cfg/apk not processed at boot"
    grep -q 'CFG/repositories' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: custom apk repositories saved" \
        || echo "FAIL: custom repositories not saved"
    [ -f /mnt/rootfs/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch ] \
        && echo "OK: launcher present" \
        || echo "FAIL: launcher missing"
    # v0.19.0: NetworkManager config must ride the persistence layer, and
    # the restore must actually overwrite user files. The old restore used
    # -xzpkf ("k" = keep-old-files) on pass A and tar -k on pass B, so
    # busybox tar aborted at the first image file it met and neither the
    # NM profiles nor any conf.d/dispatcher.d key ever came back.
    grep -q 'etc/NetworkManager' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: whole NM config tree captured by cpz-save" \
        || echo "FAIL: cpz-save does not save /etc/NetworkManager"
    grep -q 'etc/NetworkManager/system-connections' /mnt/rootfs/etc/cpz-restore.start \
        && grep -q 'etc/NetworkManager/conf.d' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: NM profiles + global config restored at boot" \
        || echo "FAIL: NM config missing from cpz-restore"
    grep -q 'tar -xzpkf' /mnt/rootfs/etc/cpz-restore.start \
        && echo "FAIL: restore still passes -k (keep-old-files) — archive is ignored" \
        || echo "OK: restore overwrites with the archived user data"
    grep -q 'nmcli connection reload' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: restored NM profiles are re-read via nmcli" \
        || echo "FAIL: NM never re-reads the restored profiles"
    grep -q 'umask 077' /mnt/rootfs/usr/local/bin/cpz-save \
        && echo "OK: PSK-bearing archive is created 0600" \
        || echo "FAIL: save archive is world-readable (leaks Wi-Fi PSKs)"
    # v0.21.2: password changes are saved to a separate root-only file and
    # merged by name at boot. The actual merge is exercised by the
    # container simulation (fake /cfg); here only the shipped hooks are
    # checked, because the image is aarch64 and cannot run on the builder.
    grep -q 'shadow-users' /mnt/rootfs/usr/local/bin/cpz-save \
        && grep -q 'shadow-users' /mnt/rootfs/etc/cpz-restore.start \
        && echo "OK: root/cpz password entries saved to /cfg and merged at boot" \
        || echo "FAIL: password persistence hook missing (shadow-users)"
    # v0.21.0: /cfg card growth (cpz-grow.start) — the device-side half of
    # the persistence story: a card written by dd/Imager/Etcher/Windows/macOS
    # gets its CPZDATA partition from the device itself. The tooling it needs
    # must be in the image, it must run BEFORE cpz-restore.start, and it must
    # be the guarded version (never formats a partition it did not create).
    [ -x /mnt/rootfs/etc/local.d/cpz-grow.start ] \
        && echo "OK: cpz-grow.start present and executable" \
        || echo "FAIL: cpz-grow.start missing or not executable"
    # v0.21.11: cpz-restore moved to the boot runlevel (before applaunch/
    # dropbear/networkmanager), so it now runs BEFORE every local.d script.
    # On a raw-dd card cpz-grow (local.d) creates p3 and reboots; the NEXT
    # boot's cpz-restore (boot runlevel) then mounts it — its 15 s wait for
    # /dev/mmcblk0p3 covers that order.
    [ ! -e /mnt/rootfs/etc/local.d/cpz-restore.start ] \
        && echo "OK: cpz-restore no longer runs in local.d" \
        || echo "FAIL: cpz-restore still in local.d (grow ordering undefined)"
    # Alpine 3.24 splits these across /sbin and /usr/sbin (sfdisk, mkfs.ext4,
    # e2fsck, blkid live in /sbin; resize2fs and dumpe2fs live in
    # /usr/sbin). ls with two args exits 1 when either is missing, so test
    # each path on its own.
    for b in sfdisk mkfs.ext4 e2fsck resize2fs dumpe2fs blkid; do
        found=0
        for p in /mnt/rootfs/sbin/$b /mnt/rootfs/usr/sbin/$b \
                 /mnt/rootfs/usr/bin/$b /mnt/rootfs/bin/$b; do
            [ -e "$p" ] && found=1
        done
        [ "$found" = 1 ] \
            && echo "OK: $b installed (CPZDATA growth)" \
            || echo "FAIL: $b missing — cpz-grow.start cannot do its job"
    done
    grep -q '\-\-no-tell-kernel' /mnt/rootfs/etc/local.d/cpz-grow.start \
        && echo "OK: cpz-grow does not ask the kernel to re-read a mounted disk" \
        || echo "FAIL: cpz-grow would hit EBUSY on BLKRRPART"
    grep -q 'cat "$FLAG"' /mnt/rootfs/etc/local.d/cpz-grow.start \
        && echo "OK: cpz-grow only formats a partition it created" \
        || echo "FAIL: cpz-grow could format a foreign CPZDATA partition"
    grep -q 'save.tar.gz' /mnt/rootfs/etc/local.d/cpz-grow.start \
        && echo "OK: cpz-grow parks the PSK snapshot before resizing" \
        || echo "FAIL: cpz-grow resizes without a snapshot backup"
    # the flasher shipped in the release ZIP: --no-update is not an sfdisk
    # option and used to make the stale-p3 delete fail silently, so a reflash
    # created an overlapping p4 entry (v0.21.0 fix). Check code only — the
    # file documents the trap by name, so comments must not trip this.
    sed -n '/^[^#]/p' "$REPO"/build/flash-cpz.sh | grep -q '\-\-no-update' \
        && echo "FAIL: flash-cpz.sh still passes the non-existent --no-update" \
        || echo "OK: flash-cpz.sh deletes the stale p3 entry for real"
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
