#!/bin/sh
# build/26-apps.sh — host-side orchestrator: build the Files and Camera
# applications (native aarch64/musl, Alpine 3.24) and install them into
# the running cpz-rootfs container.
#
# Called by build/20-rootfs.sh after build/25-launcher.sh. Requires the
# cpz-rootfs container, an arm64 binfmt, and the persistent
# cpz-apps-build container (created on first run; kept between builds so
# CMake/Ninja only recompile what changed).
#
# Sources are pinned in build/INPUTS.md and cloned under build/apps-src/
# (gitignored). Camera is pinned to v1.0.2: the image's Alpine libcamera
# is 0.7.1, while Camera 1.0.3+ requires 0.7.2/0.8 ABI. The single build
# patch (build/patches/camera-native-musl.patch) drops the compiler's own
# /usr/include from Camera's target include lists — an explicit -isystem
# /usr/include breaks Alpine musl's fortify include_next headers.
#
# Runtime deps installed by build/20-rootfs.sh: ffmpeg (Files video),
# libcamera/libcamera-ipa (Camera), libv4l (v4l2 backend), cjson/fmt
# (Camera), freetype/libpng/libjpeg-turbo/zlib.
set -eu

REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS=cpz-rootfs
CT=cpz-apps-build
JOBS=${J:-8}
SRC="$REPO/build/apps-src"
SRC_IN_CT=/repo/build/apps-src

FILES_REF=af673336af3aeb3281c20575d2436b93ea4353f9
CAMERA_REF=v1.0.2
LVGL_REF=v9.5.0
SPDLOG_REF=v1.17.0
SMOOTH_UI_REF=v2.13.0
MINIAUDIO_REF=0.11.25
BOX2D_REF=v3.1.1

# --- 1. build container (reused if alive) ---
if ! docker exec "$CT" true >/dev/null 2>&1; then
    echo "== creating $CT (linux/arm64 alpine:3.24) =="
    docker rm -f "$CT" >/dev/null 2>&1 || true
    docker run -d --platform linux/arm64 --name "$CT" \
        -v "$REPO_HOST:/repo" alpine:3.24 sleep infinity >/dev/null
fi

if ! docker exec "$CT" test -e /etc/cpz-apps-ready; then
    echo "== installing app build dependencies in $CT =="
    docker exec "$CT" apk add --no-cache --quiet \
        build-base cmake ninja git pkgconf python3 py3-pip py3-pillow py3-lz4 \
        pulseaudio-dev freetype-dev libpng-dev libjpeg-turbo-dev zlib-dev \
        libcamera-dev v4l-utils-dev fmt-dev cjson-dev linux-headers \
        file binutils
    docker exec "$CT" pip install --break-system-packages -q pypng
    docker exec "$CT" touch /etc/cpz-apps-ready
else
    echo "== reusing existing $CT (incremental build) =="
fi

# --- 2. pinned sources ---
mkdir -p "$SRC"
clone_at() {
    path=$1
    url=$2
    ref=$3
    if [ ! -d "$path/.git" ]; then
        git clone -q "$url" "$path"
    fi
    git -C "$path" fetch -q --depth 1 origin "$ref" 2>/dev/null || true
    # Do not touch the worktree when it is already at the pinned commit:
    # checkout rewrites timestamps and forces CMake/Ninja to rebuild the
    # whole LVGL tree on every image build.
    current=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
    target=$(git -C "$path" rev-parse "$ref^{commit}" 2>/dev/null || echo "$ref")
    if [ "$current" != "$target" ]; then
        git -C "$path" checkout -q --force "$ref"
    fi
}

echo "== checking pinned sources =="
clone_at "$SRC/Files" https://github.com/CardputerZero/Files.git "$FILES_REF"
mkdir -p "$SRC/Files/dependencies"
clone_at "$SRC/Files/dependencies/lvgl" https://github.com/lvgl/lvgl.git "$LVGL_REF"
clone_at "$SRC/Files/dependencies/spdlog" https://github.com/gabime/spdlog.git "$SPDLOG_REF"
clone_at "$SRC/Files/dependencies/smooth_ui_toolkit" \
    https://github.com/Forairaaaaa/smooth_ui_toolkit.git "$SMOOTH_UI_REF"
clone_at "$SRC/Files/dependencies/miniaudio" https://github.com/mackron/miniaudio.git "$MINIAUDIO_REF"
clone_at "$SRC/Files/dependencies/box2d" https://github.com/erincatto/box2d.git "$BOX2D_REF"
clone_at "$SRC/Camera" https://github.com/CardputerZero/Camera.git "$CAMERA_REF"

echo "== applying the Camera native-musl build patch =="
PATCH="$REPO/build/patches/camera-native-musl.patch"
if git -C "$SRC/Camera" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "patch already applied"
elif git -C "$SRC/Camera" apply --check "$PATCH"; then
    git -C "$SRC/Camera" apply "$PATCH"
else
    echo "FAIL: Camera patch does not apply; upstream tree changed?" >&2
    exit 1
fi

# --- 3. container-side preparation ---
# Alpine's libcamera-dev installs headers one level too deep for Camera
# (usr/include/libcamera/libcamera/*.h). Flatten it inside the build
# container only; the target image's headers are not used at runtime.
docker exec "$CT" sh -c '
set -e
if [ ! -e /usr/include/libcamera/camera.h ]; then
    cd /usr/include/libcamera
    for f in libcamera/*; do ln -sfn "$f" "$(basename "$f")"; done
fi
cp /repo/build/apps-src/Files/dependencies/miniaudio/miniaudio.h /usr/include/miniaudio.h
test -f /usr/include/libcamera/camera.h
test -f /usr/include/miniaudio.h
'

# --- 4. build Files (FBDEV + ALSA, no PulseAudio server on this image) ---
echo "== building Files =="
docker exec "$CT" sh -c "
set -e
cd $SRC_IN_CT/Files
cmake -S . -B build/cpz -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DFILES_USE_SDL=OFF \
    -DFILES_USE_PULSEAUDIO=OFF \
    -DBUILD_TESTING=OFF
cmake --build build/cpz -j$JOBS
test -x dist/M5CardputerZero-Files
"

# --- 5. build Camera (FBDEV + libcamera 0.7.1 ABI) ---
echo "== building Camera =="
docker exec "$CT" sh -c "
set -e
cd $SRC_IN_CT/Camera
cmake -S . -B build/cpz -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_DESKTOP=OFF \
    -DCM0_SDK_ROOT=/ \
    -DPTHREAD_LIBRARY=/usr/lib/libc.so \
    -DM_LIBRARY=/usr/lib/libc.so \
    -DFETCHCONTENT_SOURCE_DIR_LVGL=$SRC_IN_CT/Files/dependencies/lvgl
cmake --build build/cpz --target camera_app -j$JOBS
test -x build/cpz/camera_app
"

# --- 6. sanity: both binaries must be aarch64 musl ELF ---
docker exec "$CT" sh -c "
set -e
for bin in $SRC_IN_CT/Files/dist/M5CardputerZero-Files $SRC_IN_CT/Camera/build/cpz/camera_app; do
    desc=\$(file \"\$bin\")
    echo \"\$desc\" | grep -q 'ARM aarch64' \
        || { echo \"FAIL: \$bin is not aarch64\"; exit 1; }
    echo \"\$desc\" | grep -q 'interpreter /lib/ld-musl-aarch64' \
        || { echo \"FAIL: \$bin is not musl\"; exit 1; }
    echo \"OK: \$bin aarch64/musl ELF\"
done
"

# --- 7. install into the rootfs container ---
echo "== installing Files + Camera into $ROOTFS =="
docker exec "$ROOTFS" sh -c "
set -e
mkdir -p /usr/share/APPLaunch/bin
cp /repo/build/apps-src/Files/dist/M5CardputerZero-Files \
   /usr/share/APPLaunch/bin/M5CardputerZero-Files
cp /repo/build/apps-src/Camera/build/cpz/camera_app \
   /usr/share/APPLaunch/bin/camera_app
chmod 0755 /usr/share/APPLaunch/bin/M5CardputerZero-Files \
           /usr/share/APPLaunch/bin/camera_app

# Camera runtime assets: current path + the compatibility path used by the
# original app lookup (/usr/share/CameraApp/assets).
mkdir -p /usr/share/camera_app/fonts /usr/share/camera_app/audio \
         /usr/share/camera_app/images \
         /usr/share/CameraApp/assets
cp -a /repo/build/apps-src/Camera/assets/fonts/. /usr/share/camera_app/fonts/
cp -a /repo/build/apps-src/Camera/assets/audio/. /usr/share/camera_app/audio/
cp -a /repo/build/apps-src/Camera/assets/images/. /usr/share/camera_app/images/
cp -a /repo/build/apps-src/Camera/assets/fonts /usr/share/CameraApp/assets/
cp -a /repo/build/apps-src/Camera/assets/audio /usr/share/CameraApp/assets/
chown -R root:root /usr/share/camera_app /usr/share/CameraApp \
    /usr/share/APPLaunch/bin

# The image ships the .desktop entries and icons in rootfs-overlay; assert
# they are present so a stale rootfs cannot silently drop the apps.
test -s /usr/share/APPLaunch/applications/files.desktop
test -s /usr/share/APPLaunch/applications/camera_app.desktop
test -s /usr/share/APPLaunch/share/images/files.png
test -s /usr/share/APPLaunch/share/images/camera1.png
ls -la /usr/share/APPLaunch/bin/ /usr/share/APPLaunch/applications/
"

echo "== recording app provenance =="
{
    echo "files: $(git -C "$SRC/Files" log --oneline -1 2>/dev/null || echo 'unknown')"
    echo "camera: $(git -C "$SRC/Camera" describe --tags --always 2>/dev/null || echo 'unknown')"
    echo "camera patch: build/patches/camera-native-musl.patch"
} | tee /tmp/cpz-apps-build-info.txt

echo "== 26-apps COMPLETE =="