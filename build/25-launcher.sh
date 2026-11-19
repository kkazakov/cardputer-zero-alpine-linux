#!/bin/sh
# build/25-launcher.sh — host-side orchestrator: build the APPLaunch
# launcher (Alpine musl, aarch64) and install it into the running
# cpz-rootfs container.
#
# Called by build/20-rootfs.sh after rootfs-configure.sh, before the
# `docker export`. Requires: the cpz-rootfs container running (created
# by 20-rootfs.sh), the launcher checkout at $REPO_HOST/launcher (the
# `alpine` branch of kkazakov/cardputer-zero-launcher-alpine), docker
# binfmt for arm64.
#
# Why native-in-container: the launcher's upstream cross profile links
# a glibc sysroot; this image is musl. Building natively inside
# linux/arm64 alpine:3.24 (emulated) gives an ABI-exact binary against
# exactly the libraries the image installs (same Alpine release).
#
# The build container is deliberately KEPT ALIVE between runs: scons
# is incremental, so image rebuilds recompile only what changed instead
# of paying the full ~15 min qemu tax every time. Delete it with
# `docker rm -f cpz-launcher-build` to force a clean rebuild.
#
# Inputs (env):
#   REPO_HOST          repo path as seen by the docker daemon
#   APPLAUNCH_VERSION version string (X.Y.Z[-tag]); default 1.0.0-alpine
set -eu

REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
VER=${APPLAUNCH_VERSION:-1.0.0-alpine}
CT=cpz-launcher-build
ROOTFS=cpz-rootfs
J=${J:-8}

# --- 1. build container (reused if alive) ---
if ! docker exec "$CT" true >/dev/null 2>&1; then
    echo "== creating $CT (linux/arm64 alpine:3.24) =="
    docker rm -f "$CT" >/dev/null 2>&1 || true
    docker run -d --platform linux/arm64 --name "$CT" \
        -v "$REPO_HOST/launcher:/repo" alpine:3.24 sleep infinity >/dev/null
    docker exec "$CT" apk add --no-cache --quiet \
        build-base python3 scons py3-parse py3-requests py3-tqdm \
        pkgconf freetype-dev curl-dev libinput-dev libxkbcommon-dev \
        eudev-dev dbus-dev glib-dev unzip wget file
else
    echo "== reusing existing $CT (incremental build) =="
fi

echo "== pre-seeding pinned third-party sources =="
docker exec "$CT" sh -c '
set -e
cd /repo/SDK/github_source
if [ ! -d eventpp ]; then
  wget -q https://github.com/wqking/eventpp/archive/c472fb22e71ead0e58ff7df89e12c66b0bdfb533.zip -O /tmp/eventpp.zip
  unzip -q -o /tmp/eventpp.zip -d /tmp
  rm -rf eventpp && mv /tmp/eventpp-c472fb22e71ead0e58ff7df89e12c66b0bdfb533 eventpp
fi
if [ ! -d C-Thread-Pool ]; then
  wget -q https://github.com/Pithikos/C-Thread-Pool/archive/refs/heads/master.zip -O /tmp/ctp.zip
  unzip -q -o /tmp/ctp.zip -d /tmp
  rm -rf C-Thread-Pool && mv /tmp/C-Thread-Pool-master C-Thread-Pool
fi
ls eventpp/include/eventpp/callbacklist.h C-Thread-Pool/thpool.c >/dev/null
echo "sources pre-seeded OK"
'

echo "== applying the Calculator native-build patch =="
# Upstream hardwires every non-cross Calculator build to the SDL
# simulator; the patch (carried by the launcher fork) targets FBDEV +
# EVDEV when the host is aarch64. Applied idempotently to the submodule
# working tree — the pinned commit itself stays untouched.
docker exec "$CT" sh -c '
set -e
PATCH=/repo/deploy/alpine/patches/calculator-native-fbdev.patch
cd /repo/projects/Calculator
patch -p1 --dry-run -f -s < "$PATCH" 2>/dev/null \
  && patch -p1 -s < "$PATCH" \
  || echo "patch already applied (or tree dirty) — continuing"
'

echo "== building APPLaunch + Calculator (version $VER) =="
docker exec "$CT" sh -c "
cd /repo/projects/APPLaunch
export CONFIG_REPO_AUTOMATION=y
export APPLAUNCH_VERSION=$VER
export APPLAUNCH_CHANNEL=alpine
scons -j$J
"
docker exec "$CT" sh -c "
cd /repo/projects/Calculator
export CONFIG_REPO_AUTOMATION=y
# Calculator's SConstruct requires an explicit profile (unlike APPLaunch);
# config_defaults.mk is its native device profile (FBDEV).
export CONFIG_DEFAULT_FILE=config_defaults.mk
scons -j$J
"

echo "== staging the deployable tree + sanity checks =="
docker exec "$CT" sh -c '
set -e
cd /repo
LAUNCHER=projects/APPLaunch/dist/M5CardputerZero-APPLaunch
CALC=projects/Calculator/dist/M5CardputerZero-Calculator
[ -f "$CALC" ] || CALC=projects/Calculator/dist/Calculator
test -f "$LAUNCHER" || { echo "FAIL: launcher binary missing"; exit 1; }
test -f "$CALC" || { echo "FAIL: calculator binary missing"; exit 1; }
file "$LAUNCHER" "$CALC"
echo "$LAUNCHER: $(file "$LAUNCHER")" | grep -q "ARM aarch64" \
  || { echo "FAIL: launcher is not aarch64"; exit 1; }
file "$LAUNCHER" | grep -q "interpreter /lib/ld-musl-aarch64" \
  || { echo "FAIL: launcher is not linked against musl"; exit 1; }

STAGE=/repo/dist-alpine/stage
rm -rf /repo/dist-alpine "$STAGE"
mkdir -p "$STAGE/APPLaunch/bin"
cp -a projects/APPLaunch/dist/APPLaunch/. "$STAGE/APPLaunch/"
cp "$LAUNCHER" "$STAGE/APPLaunch/bin/M5CardputerZero-APPLaunch"
cp "$CALC" "$STAGE/APPLaunch/bin/M5CardputerZero-Calculator"
ls -la "$STAGE/APPLaunch/bin/"
'

echo "== packing the tree =="
docker exec "$CT" sh -c "
set -e
tar -C /repo/dist-alpine/stage -czf /repo/dist-alpine/applaunch-$VER.tar.gz APPLaunch
rm -rf /repo/dist-alpine/stage
echo tarball: \$(du -h /repo/dist-alpine/applaunch-$VER.tar.gz | cut -f1)
tar -tzf /repo/dist-alpine/applaunch-$VER.tar.gz | head -8
"

echo "== installing into the $ROOTFS container =="
# The rootfs container has the whole repo mounted at /repo, so it reads
# the tarball straight from the launcher checkout — no docker cp needed.
docker exec "$ROOTFS" sh -c "
set -e
mkdir -p /usr/share
tar -xzf /repo/launcher/dist-alpine/applaunch-$VER.tar.gz -C /usr/share/
cp /repo/launcher/deploy/alpine/applaunch.initd  /etc/init.d/applaunch
cp /repo/launcher/deploy/alpine/applaunch.confd /etc/conf.d/applaunch
chmod 0755 /etc/init.d/applaunch
chown -R root:root /usr/share/APPLaunch /etc/init.d/applaunch /etc/conf.d/applaunch
rc-update add applaunch default
rc-update show default | grep -E 'applaunch|networkmanager|dbus|bluetooth' || true
ls -la /usr/share/APPLaunch/bin/
"

echo "== recording launcher provenance =="
# Host-side: the build container carries no git; the checkout lives on
# this host (or the docker host), where the sha and branch are readable.
{
    echo "launcher: $(git -C "$REPO_HOST/launcher" log --oneline -1 2>/dev/null || echo 'unknown')"
    echo "launcher branch: $(git -C "$REPO_HOST/launcher" branch --show-current 2>/dev/null || echo 'unknown')"
    echo "applaunch version: $VER"
} | tee /tmp/cpz-launcher-build-info.txt

echo "== 25-launcher COMPLETE =="
