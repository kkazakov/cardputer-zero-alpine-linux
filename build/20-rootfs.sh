#!/bin/sh
# build/20-rootfs.sh — host-side orchestrator for the Alpine aarch64 rootfs.
#
# Builds the rootfs inside a linux/arm64 alpine:3.24 Docker container
# (emulated; requires binfmt — see build/build-image.sh prerequisites),
# grafts the harvested Phase-A BSP via build/rootfs-configure.sh, then
# exports the container filesystem to /work/rootfs.tar on the cpz-work
# volume (daemon-side; nothing large streams through this client).
set -eu

REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
CONTAINER=cpz-rootfs
BUILDER=cpz-builder
APK_FLAGS="--no-cache --quiet"
PKGS="openrc busybox-openrc eudev eudev-openrc eudev-libs kbd dropbear
wpa_supplicant iw ifupdown-ng doas i2c-tools alsa-utils alsa-lib usbutils
tzdata openssl ca-certificates mkinitfs terminus-font"

# --- builder container must exist (owns the /work volume) ---
if ! docker exec "$BUILDER" true >/dev/null 2>&1; then
    docker run -d --privileged --name "$BUILDER" -v cpz-work:/work \
        alpine:3.20 sleep infinity >/dev/null
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
    "apk add --no-cache --quiet dropbear-openrc wpa_supplicant-openrc 2>/dev/null || true"

echo "== configuring rootfs (in-container) =="
docker exec "$CONTAINER" sh /repo/build/rootfs-configure.sh

echo "== exporting rootfs tar to the volume =="
docker export "$CONTAINER" | docker exec -i "$BUILDER" sh -c 'cat > /work/rootfs.tar'
docker exec "$BUILDER" sh -c 'ls -la /work/rootfs.tar && du -h /work/rootfs.tar'

echo "== 20-rootfs COMPLETE =="
