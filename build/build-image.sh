#!/bin/sh
# build/build-image.sh — CPZ-Alpine full pipeline orchestrator.
#
# Prerequisites (build host):
#   - Docker with linux/arm64 emulation (once per host):
#       docker run --rm --privileged tonistiigi/binfmt --install arm64
#   - docker volume:        docker volume create cpz-work
#   - REPO_HOST default assumes this checkout lives at
#     /home/wasp/projects/cardputer-zero-alpine (override via REPO_HOST).
#
# Pipeline:
#   10-harvest.sh  — offline BSP harvest from the M5 stock image
#   20-rootfs.sh   — Alpine aarch64 rootfs in an emulated container
#   30-image.sh    — flashable image assembly + verification
#
# All stage scripts are re-runnable; each one recreates its outputs.
set -eu

REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
export REPO_HOST

echo "=== CPZ-Alpine build — $(date -u) ==="

if [ ! -f "$REPO_HOST/harvest/MANIFEST.sha256" ]; then
    echo "=== Stage 10: BSP harvest (needs /work/vendor/stock.img.xz in the volume) ==="
    docker run --rm --privileged -v cpz-work:/work -v "$REPO_HOST:/repo" \
        alpine:3.20 sh -c \
        'apk add --no-cache util-linux e2fsprogs kmod cpio gzip >/dev/null && sh /repo/build/10-harvest.sh'
else
    echo "=== Stage 10: harvest present, skipping (rm harvest/ to redo) ==="
fi

echo "=== Stage 20: Alpine rootfs ==="
sh "$REPO_HOST/build/20-rootfs.sh"

echo "=== Stage 30: image assembly ==="
docker run --rm --privileged -v cpz-work:/work -v "$REPO_HOST:/repo" \
    alpine:3.20 sh -c \
    'apk add --no-cache util-linux dosfstools mtools e2fsprogs gzip file >/dev/null && sh /repo/build/30-image.sh'

echo "=== DONE — see images/ and build/verification-report.txt ==="
