#!/bin/sh
# build/rootfs-configure.sh — IN-CONTAINER rootfs configuration.
#
# Runs as root inside the cpz-rootfs container (linux/arm64 alpine:3.24):
#   /repo — bind mount of the cardputer-zero-alpine checkout
# Grafts the harvested Phase-A BSP (kernel modules, firmware, keymap,
# udev rules, console font), applies rootfs-overlay/, wires OpenRC
# runlevels and users. No initramfs in v0.1 (see /etc/mkinitfs notes).
set -eu

REPO=/repo
H=$REPO/harvest
KVER=$(ls "$H/modules" | grep 'rpi-v8' | head -1)
echo "== kernel: $KVER =="

echo "== grafting kernel modules =="
mkdir -p /lib/modules
cp -a "$H/modules/$KVER" /lib/modules/

echo "== grafting firmware =="
mkdir -p /lib/firmware
cp -a "$H/firmware/brcm" "$H/firmware/cypress" "$H/firmware/synaptics" /lib/firmware/
cp -a "$H/firmware/bmi270-init-data.fw" /lib/firmware/
cp -a "$H/firmware/regulatory.db-debian" /lib/firmware/regulatory.db
cp -a "$H/firmware/regulatory.db.p7s-debian" /lib/firmware/regulatory.db.p7s

echo "== grafting keymap =="
mkdir -p /usr/share/keymaps
cp -a "$H/keymaps/." /usr/share/keymaps/

echo "== grafting M5 udev rules (from dtoverlays source) =="
mkdir -p /etc/udev/rules.d
cp -a "$REPO/vendor/m5stack-linux-dtoverlays/modules/st7789v-1.0/99-cardputer-zero-lcd.rules" \
      /etc/udev/rules.d/
cp -a "$REPO/vendor/m5stack-linux-dtoverlays/modules/tca8418-1.0/99-cardputer-zero-keyboard.rules" \
      /etc/udev/rules.d/

echo "== console font (Spleentt 5x8) =="
mkdir -p /usr/share/consolefonts
cp -a "$REPO/vendor/spleentt/SpleenttMedium.psf" /usr/share/consolefonts/cpz-spleentt-5x8.psf
cp -a "$REPO/vendor/spleentt/LICENSE" /usr/share/consolefonts/cpz-spleentt-5x8.LICENSE

echo "== ownership: grafted trees must be root-owned =="
# cp -a preserved the build host's uid 1000 for the harvest sources; on the
# device these must belong to root:root.
chown -R 0:0 /lib/modules /lib/firmware /usr/share/keymaps \
    /usr/share/consolefonts /etc/udev/rules.d

echo "== applying rootfs-overlay =="
# NOTE: /etc/hosts, /etc/hostname (and resolv.conf) are docker bind-mounts
# in this container and do NOT survive `docker export` — they are written
# onto the rootfs by build/30-image.sh at assembly time instead.
mkdir -p /tmp/cpz-overlay
cp -a "$REPO/rootfs-overlay/." /tmp/cpz-overlay/
rm -f /tmp/cpz-overlay/etc/hosts /tmp/cpz-overlay/etc/hostname
cp -a /tmp/cpz-overlay/. /
rm -rf /tmp/cpz-overlay

# The overlay is authored on the build host, where a 600/644 file is normal.
# OpenRC's `local` service only runs /etc/local.d/*.start files that are
# EXECUTABLE (`[ -x "${file}" ]`), and it fails silently otherwise —
# v0.1..v0.3 shipped console.start as 0600, so the keymap, font and
# blank/unblank fix never ran. Normalize modes explicitly, do not rely on
# whatever the checkout happened to have.
echo "== overlay permissions =="
# The overlay is authored on the build host and `cp -a` preserves that
# host's uid (1000), which maps to the image's `cpz` user — /etc files
# were shipping as cpz:cpz. Everything under /etc, /usr/local/bin and
# /boot is root-owned, period.
chown -R root:root /etc /usr/local/bin /boot /usr/share/keymaps \
    /usr/share/consolefonts 2>/dev/null || true
chmod 755 /etc/local.d/*.start 2>/dev/null || true
chmod 755 /usr/local/bin/* 2>/dev/null || true
chmod 644 /etc/profile.d/*.sh 2>/dev/null || true
# v0.17.2: /etc/cpz carries the on-demand desktop config (sway.config) and
# the hotplug consent mode. It shipped 0600 root-only, so `cpz-desktop
# start` (sway as the cpz user) could not read its own config and died
# with "Unable to open /etc/cpz/sway.config". Not secret — world-readable.
chmod 644 /etc/cpz/* 2>/dev/null || true
ls -l /etc/local.d/ /etc/profile.d/ /etc/cpz/

# THE BIG ONE (v0.7): Docker's marker file /.dockerenv is created in every
# container and `docker export` captured it into the rootfs. OpenRC's
# container autodetection looks for it, concludes "I am in a container"
# and silently skips EVERY service whose init script carries
# `keyword -docker` — devfs, sysfs, procfs, udev*, fsck, root,
# localmount, hostname, hwclock, seedrng, networking. Result since v0.2:
# no /sys, no udev, no hostname, no /boot mount — while the runlevel
# symlinks sat there looking correct. Remove the marker so OpenRC runs
# everything.
rm -f /.dockerenv /run/.containerenv

# /boot must exist as a mountpoint: fstab mounts the FAT partition there,
# localmount refuses otherwise ("mount point does not exist") and the
# whole /boot path (cpzdiag report, future kernel swaps) breaks.
mkdir -p /boot

# /cfg: mount point for the CPZDATA persistence partition (p3 at the
# fixed 4 GiB offset, created by flash-cpz.sh). Not in fstab on purpose
# — cpz-restore.start mounts it if present, so raw-dd cards (no p3)
# boot without a localmount failure.
mkdir -p /cfg

# v0.14 launcher state + NetworkManager profile dirs:
#  /var/lib/applaunch — the launcher's settings + config.json
#  /etc/NetworkManager/system-connections — Wi-Fi profiles (PSK-bearing,
#  created root-only; 30-image.sh bakes a keyfile here when the build
#  has build/wifi-secret)
mkdir -p /var/lib/applaunch
mkdir -p -m 0700 /etc/NetworkManager/system-connections
chown root:root /var/lib/applaunch /etc/NetworkManager 2>/dev/null || true

echo "== timezone =="
ln -sf /usr/share/zoneinfo/Europe/Sofia /etc/localtime
echo "Europe/Sofia" > /etc/timezone

echo "== OpenRC runlevels =="
svc_add() {
    if [ -e "/etc/init.d/$1" ]; then
        rc-update add "$1" "$2"
    else
        echo "WARN: no /etc/init.d/$1 — skipped"
    fi
}
svc_add devfs sysinit
svc_add sysfs sysinit
svc_add procfs sysinit
svc_add udev sysinit
svc_add udev-trigger sysinit
svc_add udev-settle sysinit
svc_add fsck boot
svc_add root boot
svc_add mtab boot
svc_add localmount boot
svc_add bootmisc boot
svc_add hostname boot
svc_add hwclock boot
svc_add modules boot
svc_add seedrng boot
svc_add sysctl boot
svc_add syslog boot
# v0.14: NetworkManager replaces ifupdown-ng + wpa_supplicant (the
# launcher's Wi-Fi/Ethernet settings drive nmcli). The standalone
# `networking` and `wpa_supplicant` services must NOT run alongside NM —
# two supplicants fight over wlan0.
svc_add networkmanager default
svc_add dbus default
svc_add dropbear default
svc_add crond default
svc_add local default
svc_add bluetooth default
# `applaunch` (the launcher UI, OpenRC) is added to default by
# build/25-launcher.sh together with its init script.
svc_add killprocs shutdown
svc_add mount-ro shutdown
svc_add savecache shutdown

echo "== users =="
echo "root:alpine" | chpasswd
adduser -D -s /bin/ash cpz 2>/dev/null || true
echo "cpz:alpine" | chpasswd
addgroup cpz wheel 2>/dev/null || true
# v0.18.0: the launcher runs as cpz (not root) and must reach the hardware
# it talks to directly:
#   video — /dev/fb1 (the LCD launcher surface)
#   input — /dev/input/by-path/... (tca8418 keypad, its evdev runtime keymap)
#   audio — /dev/snd/* (ALSA mixer for the volume keys + Speaker page)
#   i2c   — /dev/i2c-1 (BQ27220 gauge, RX8130 RTC, m5ioe1 backlight)
#   seat  — seatd socket group for the on-demand HDMI session
addgroup -S i2c 2>/dev/null || true   # package-created groups first, ours after
for g in video input audio i2c seat; do addgroup cpz "$g" 2>/dev/null || true; done

# v0.18.0: cpz gets full passwordless sudo — the single-user device's
# replacement for upstream's polkit/sudo approval flow (RTC write, power
# actions, cpz-desktop's seatd/runtime-dir steps). sudo refuses
# group/world-writable files, so force 0440 root:root.
chown root:root /etc/sudoers.d/cpz 2>/dev/null || true
chmod 0440 /etc/sudoers.d/cpz 2>/dev/null || true

# v0.18.0: the launcher (as cpz) writes its config.json and the
# hdmi-desktop preference here.
chown -R cpz:cpz /var/lib/applaunch 2>/dev/null || true

echo "== script syntax checks =="
for f in /etc/local.d/console.start /etc/profile.d/cpz-status.sh; do
    sh -n "$f" && echo "OK: $f"
done

echo "== sanity report =="
{
    echo "--- kernel: $KVER"
    echo "--- runlevels:"
    rc-update show 2>/dev/null || true
    echo "--- /etc/modules:"
    cat /etc/modules
    echo "--- extra/ modules:"
    ls /lib/modules/$KVER/extra/ 2>/dev/null || echo "MISSING extra/"
    echo "--- firmware symlinks resolve:"
    for l in /lib/firmware/brcm/*compute-module*.bin \
             /lib/firmware/brcm/*compute-module*.txt \
             /lib/firmware/brcm/*compute-module*.hcd \
             /lib/firmware/brcm/*zero-2-w*.hcd; do
        t=$(readlink -f "$l" 2>/dev/null || true)
        if [ -n "$t" ] && [ -e "$t" ]; then
            echo "OK: ${l#/lib/firmware/brcm/}"
        else
            echo "BROKEN: $l"
        fi
    done
    echo "--- regulatory.db:"
    ls -la /lib/firmware/regulatory.db* 2>/dev/null || echo "MISSING"
    echo "--- keymap + font:"
    ls -la /usr/share/keymaps/ | grep tca8418 || echo "KEYMAP MISSING"
    ls -la /usr/share/consolefonts/ | grep cpz || echo "FONT MISSING"
    echo "--- inittab getty lines:"
    grep getty /etc/inittab
    echo "--- fstab:"
    cat /etc/fstab
    echo "--- apk world:"
    cat /etc/apk/world
    echo "--- hwclock/RTC service enabled:"
    ls -la /etc/runlevels/boot/ 2>/dev/null || true
}
echo "== rootfs-configure COMPLETE =="
