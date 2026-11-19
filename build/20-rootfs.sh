#!/bin/sh
# build/20-rootfs.sh — host-side orchestrator for the Alpine aarch64 rootfs.
#
# Builds the rootfs inside a linux/arm64 alpine:3.24 Docker container
# (emulated; requires binfmt — see build/build-image.sh prerequisites),
# grafts the harvested Phase-A BSP via build/rootfs-configure.sh, builds
# and installs the APPLaunch launcher via build/25-launcher.sh, then
# exports the container filesystem to /work/rootfs.tar on the cpz-work
# volume (daemon-side; nothing large streams through this client).
set -eu

REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
CONTAINER=cpz-rootfs
BUILDER=cpz-builder
APK_FLAGS="--no-cache --quiet"
# v0.17: dbus runs the system bus (bluez + NetworkManager) — also used by
# the HDMI desktop stack; networkmanager owns wlan0/eth0 now (the launcher's
# Wi-Fi/Ethernet settings drive nmcli — it replaces the ifupdown-ng /
# wpa_supplicant boot path); the rest of the additions are the APPLaunch
# launcher binary's runtime link set
# (freetype/libinput/libxkbcommon/glib/curl/libstdc++) plus bash for its
# CLI terminal app and alsa-lib for Miniaudio on this Pulse-free image.
#
# v0.17.2 (field feedback): Alpine splits NetworkManager's Wi-Fi support and
# CLI into separate packages — without them the launcher's Wi-Fi toggle was
# dead (nmcli: not found, and NM marks every wlan0 as unmanaged when its
# device plugin is absent). wpa_supplicant is the backend NM spawns (Alpine's
# networkmanager does not depend on it). swaybg stops sway's background
# helper error on the HDMI session.
PKGS="openrc busybox-openrc eudev eudev-openrc eudev-libs kbd dropbear
iw doas i2c-tools alsa-utils alsa-lib usbutils
tzdata openssl ca-certificates mkinitfs terminus-font bluez bluez-openrc
sway foot seatd seatd-openrc mesa-dri-gallium xkeyboard-config
waybar bemenu dbus dbus-openrc tilix swaybg
freetype libinput libxkbcommon dbus-libs glib curl libstdc++ bash
networkmanager networkmanager-openrc networkmanager-wifi networkmanager-cli
wpa_supplicant sudo"

# --- builder container must exist (owns the /work volume, runs 30-image) ---
if ! docker exec "$BUILDER" true >/dev/null 2>&1; then
    docker run -d --privileged --name "$BUILDER" -v cpz-work:/work \
        -v "$REPO_HOST:/repo" alpine:3.20 sleep infinity >/dev/null
fi

# --- (re)create the rootfs container ---
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --platform linux/arm64 --name "$CONTAINER" \
    -v cpz-work:/work -v "$REPO_HOST:/repo" alpine:3.24 sleep infinity >/dev/null

echo "== installing packages =="
docker exec "$CONTAINER" apk update $APK_FLAGS
docker exec "$CONTAINER" apk add $APK_FLAGS $PKGS
# optional openrc split packages — absence is not fatal
docker exec "$CONTAINER" sh -c \
    "apk add --no-cache --quiet dropbear-openrc 2>/dev/null || true"

echo "== configuring rootfs (in-container) =="
docker exec "$CONTAINER" sh /repo/build/rootfs-configure.sh

echo "== building + installing the launcher (build/25-launcher.sh) =="
REPO_HOST="$REPO_HOST" sh "$(dirname "$0")/25-launcher.sh"

echo "== exporting rootfs tar to the volume =="
docker export "$CONTAINER" | docker exec -i "$BUILDER" sh -c 'cat > /work/rootfs.tar'
docker exec "$BUILDER" sh -c 'ls -la /work/rootfs.tar && du -h /work/rootfs.tar'

echo "== 20-rootfs COMPLETE =="
