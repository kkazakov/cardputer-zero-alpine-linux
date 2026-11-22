#!/bin/sh
# build/build-app-package.sh — clone/update a Cardputer Zero app repo,
# build it natively (aarch64/musl) inside the cpz-apps-build container,
# and produce an installable tar.gz package.
#
# Usage:
#   sh build/build-app-package.sh <github-url>            # build from URL
#   sh build/build-app-package.sh <github-url> <ref>       # build at tag/branch/commit
#   sh build/build-app-package.sh <github-url> <ref> --clean
#
# Prints the absolute path of the resulting package on success.
#
# The script detects the app type automatically:
#   - app-builder.json present → metadata-driven (Python / mixed apps)
#   - CMakeLists.txt  present → CMake/Ninja build (C++ apps)
#   - Makefile         present → make
#   - SConstruct       present → scons
#
# The output package extracts to / (tar -xzf ... -C / --overwrite).
# The device's busybox tar handles this directly.
set -eu

# --- helpers -----------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

# --- parse args ---------------------------------------------------------
GITHUB_URL="${1:?Usage: $0 <github-url> [ref] [--clean]}"
shift
REF=""
CLEAN=0
for arg; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        --help|-h) echo "Usage: $0 <github-url> [ref] [--clean]"; exit 0 ;;
        -*) die "unknown flag: $arg" ;;
        *) REF="$arg" ;;
    esac
done

# Derive repo name from URL: https://github.com/Owner/Repo.git → Repo
REPO_NAME=$(echo "$GITHUB_URL" | sed -n 's#.*/\([^/.]*\)\(\.git\)\?$#\1#p')
[ -n "$REPO_NAME" ] || die "cannot derive repo name from URL: $GITHUB_URL"

# --- paths --------------------------------------------------------------
REPO_HOST=${REPO_HOST:-/home/wasp/projects/cardputer-zero-alpine}
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/build/apps-src/$REPO_NAME"
PKG_DIR="$REPO/build/packages"
CT=cpz-apps-build
JOBS=${J:-8}

mkdir -p "$SRC" "$PKG_DIR"

# ========================================================================
# 1. clone or update the source
# ========================================================================
if [ -d "$SRC/.git" ]; then
    echo "== updating existing checkout: $SRC =="
    git -C "$SRC" fetch -q origin 2>/dev/null || true
    if [ -n "$REF" ]; then
        git -C "$SRC" checkout -q --force "$REF" || die "cannot checkout $REF"
    else
        git -C "$SRC" checkout -q --force origin/HEAD 2>/dev/null \
            || git -C "$SRC" checkout -q --force main 2>/dev/null \
            || git -C "$SRC" checkout -q --force master 2>/dev/null \
            || die "cannot determine default branch; pass an explicit <ref>"
    fi
    if [ "$CLEAN" -eq 1 ]; then
        echo "== --clean: removing build artefacts =="
        # Build artefacts may be owned by root (docker), so clean
        # inside the container if possible, otherwise try the host.
        if docker exec "$CT" true >/dev/null 2>&1; then
            SRC_IN_CT="/repo/build/apps-src/$REPO_NAME"
            docker exec "$CT" rm -rf "$SRC_IN_CT/build" 2>/dev/null || true
        fi
        rm -rf "$SRC/build" 2>/dev/null || true
    fi
else
    echo "== cloning $GITHUB_URL → $SRC =="
    if [ -n "$REF" ]; then
        git clone -q --depth 1 --branch "$REF" "$GITHUB_URL" "$SRC" 2>/dev/null \
            || { git clone -q "$GITHUB_URL" "$SRC" && git -C "$SRC" checkout -q "$REF"; }
    else
        git clone -q --depth 1 "$GITHUB_URL" "$SRC" 2>/dev/null \
            || git clone -q "$GITHUB_URL" "$SRC"
    fi
    [ -d "$SRC/.git" ] || die "clone failed"
fi

CURRENT_REF=$(git -C "$SRC" log --oneline -1 --no-decorate 2>/dev/null || echo "unknown")
echo "== source at: $CURRENT_REF =="

# ========================================================================
# 2. detect app type
# ========================================================================
STAGE="$REPO/build/.pkg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

HAS_APPBUILDER=0
HAS_CMAKE=0
HAS_MAKEFILE=0
HAS_SCONS=0

[ -f "$SRC/app-builder.json" ] && HAS_APPBUILDER=1
[ -f "$SRC/CMakeLists.txt" ]   && HAS_CMAKE=1
[ -f "$SRC/Makefile" ]         && HAS_MAKEFILE=1
[ -f "$SRC/SConstruct" ]       && HAS_SCONS=1

# ========================================================================
# 3. APP-BUILDER path (Python / metadata-driven apps)
# ========================================================================
if [ "$HAS_APPBUILDER" -eq 1 ]; then
    echo "== app type: app-builder (metadata-driven) =="

    # Parse app-builder.json
    if command -v python3 >/dev/null 2>&1; then
        PKG_NAME=$(python3 -c "
import json; d=json.load(open('$SRC/app-builder.json'))
print(d.get('package_name','$REPO_NAME').lower())
")
        VERSION=$(python3 -c "
import json; d=json.load(open('$SRC/app-builder.json'))
print(d.get('version','0.1.0'))
")
        APP_NAME=$(python3 -c "
import json; d=json.load(open('$SRC/app-builder.json'))
print(d.get('app_name','$REPO_NAME'))
")
        BIN_NAME=$(python3 -c "
import json; d=json.load(open('$SRC/app-builder.json'))
print(d.get('bin_name','${REPO_NAME}'))
")
        store_icon=$(python3 -c "
import json; d=json.load(open('$SRC/app-builder.json'))
print(d.get('store',{}).get('icon',''))
")
    else
        # grep fallback
        PKG_NAME=$(grep '"package_name"' "$SRC/app-builder.json" | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | tr '[:upper:]' '[:lower:]')
        VERSION=$(grep '"version"' "$SRC/app-builder.json" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        APP_NAME=$(grep '"app_name"' "$SRC/app-builder.json" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        BIN_NAME=$(grep '"bin_name"' "$SRC/app-builder.json" | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
        store_icon=$(grep '"icon"' "$SRC/app-builder.json" | head -1 | sed 's/.*"\([^"]*\.png\)".*/\1/')
        [ -z "$PKG_NAME" ] && PKG_NAME="$REPO_NAME"
        [ -z "$VERSION"  ] && VERSION="0.1.0"
        [ -z "$APP_NAME" ] && APP_NAME="$REPO_NAME"
        [ -z "$BIN_NAME" ] && BIN_NAME="$REPO_NAME"
    fi

    PKG_NAME="cpz-$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]')"
    echo "   package: $PKG_NAME  version: $VERSION"
    echo "   app:     $APP_NAME  binary:  $BIN_NAME"

    # --- 3a. staging directories ---
    mkdir -p "$STAGE/usr/share/APPLaunch/bin" \
             "$STAGE/usr/share/APPLaunch/applications" \
             "$STAGE/usr/share/APPLaunch/share/images" \
             "$STAGE/usr/share/APPLaunch/share/$PKG_NAME"

    # --- 3b. copy applaunch/ layout ---
    if [ -d "$SRC/applaunch" ]; then
        echo "   copying applaunch/ layout"
        [ -d "$SRC/applaunch/applications" ] && cp -a "$SRC/applaunch/applications/"* "$STAGE/usr/share/APPLaunch/applications/" 2>/dev/null || true
        [ -d "$SRC/applaunch/share" ]        && cp -a "$SRC/applaunch/share/"*        "$STAGE/usr/share/APPLaunch/share/"        2>/dev/null || true
        [ -d "$SRC/applaunch/bin" ]          && cp -a "$SRC/applaunch/bin/"*          "$STAGE/usr/share/APPLaunch/bin/"          2>/dev/null || true
    fi

    # --- 3c. copy Python source ---
    if [ -d "$SRC/src" ]; then
        echo "   copying Python source"
        cp -a "$SRC/src/." "$STAGE/usr/share/APPLaunch/share/$PKG_NAME/" 2>/dev/null || true
        find "$STAGE/usr/share/APPLaunch/share/$PKG_NAME" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
        find "$STAGE/usr/share/APPLaunch/share/$PKG_NAME" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$STAGE/usr/share/APPLaunch/share/$PKG_NAME" -type f -exec chmod 644 {} + 2>/dev/null || true
    fi

    # --- 3d. entry-point wrapper ---
    WRAPPER=""
    for candidate in "packaging/${BIN_NAME}.sh" "packaging/run.sh"; do
        [ -f "$SRC/$candidate" ] && { WRAPPER="$SRC/$candidate"; break; }
    done

    if [ -n "$WRAPPER" ]; then
        echo "   installing wrapper: $(basename "$WRAPPER") → bin/$BIN_NAME"
        # Patch hardcoded paths from the upstream .deb layout to our
        # cpz- prefixed paths (e.g. /usr/lib/mouse-jiggler →
        # /usr/lib/cpz-mouse-jiggler).
        sed -e "s|/usr/lib/${BIN_NAME}/|/usr/lib/${PKG_NAME}/|g" \
            -e "s|/usr/share/APPLaunch/share/${BIN_NAME}|/usr/share/APPLaunch/share/${PKG_NAME}|g" \
            "$WRAPPER" > "$STAGE/usr/share/APPLaunch/bin/$BIN_NAME"
        chmod 755 "$STAGE/usr/share/APPLaunch/bin/$BIN_NAME"
    elif [ -d "$SRC/src" ]; then
        echo "   creating default wrapper"
        cat > "$STAGE/usr/share/APPLaunch/bin/$BIN_NAME" <<PYWRAPPER
#!/bin/sh
set -eu
APPDIR=/usr/share/APPLaunch/share/$PKG_NAME
PYTHONPATH="\$APPDIR\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHONPATH
exec python3 -m ${BIN_NAME} "\$@"
PYWRAPPER
        chmod 755 "$STAGE/usr/share/APPLaunch/bin/$BIN_NAME"
    fi

    # --- 3e. capability launcher (caplaunch.c) ---
    if [ -f "$SRC/packaging/caplaunch.c" ]; then
        echo "   building capability launcher"
        if ! docker exec "$CT" true >/dev/null 2>&1; then
            docker rm -f "$CT" >/dev/null 2>&1 || true
            docker run -d --platform linux/arm64 --name "$CT" \
                -v "$REPO_HOST:/repo" alpine:3.24 sleep infinity >/dev/null
            docker exec "$CT" apk add --no-cache --quiet build-base >/dev/null 2>&1 || true
        fi
        mkdir -p "$STAGE/usr/lib/$PKG_NAME"
        SRC_IN_CT="/repo/build/apps-src/$REPO_NAME"
        if docker exec "$CT" sh -c \
            "gcc -O2 -static -Wall -o /tmp/caplaunch '$SRC_IN_CT/packaging/caplaunch.c'" 2>/dev/null; then
            docker cp "$CT:/tmp/caplaunch" "$STAGE/usr/lib/$PKG_NAME/caplaunch"
            chmod 755 "$STAGE/usr/lib/$PKG_NAME/caplaunch"
            docker exec "$CT" rm -f /tmp/caplaunch 2>/dev/null || true
            echo "   caplaunch: ok"
        else
            echo "   WARN: caplaunch build failed (non-fatal)" >&2
        fi
    fi

    # --- 3f. default .desktop if applaunch/ didn't have one ---
    if [ -z "$(ls -A "$STAGE/usr/share/APPLaunch/applications/" 2>/dev/null)" ]; then
        echo "   creating default .desktop"
        cat > "$STAGE/usr/share/APPLaunch/applications/${BIN_NAME}.desktop" <<DESKTOPDF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$APP_NAME
Exec=bin/$BIN_NAME
Icon=share/images/${BIN_NAME}.png
Terminal=false
Sysplause=false
DESKTOPDF
    fi

    # --- 3g. icon ---
    if [ -z "$(ls -A "$STAGE/usr/share/APPLaunch/share/images/" 2>/dev/null)" ]; then
        ICON_SRC=""
        for try in "$SRC/$store_icon" \
                   "$SRC/packaging/deb/images/${BIN_NAME}.png" \
                   "$SRC/packaging/deb/images/$(echo "$BIN_NAME" | tr '[:upper:]' '[:lower:]').png" \
                   "$SRC/assets/icon-256.png" \
                   "$SRC/assets/icon.png"; do
            [ -f "$try" ] && { ICON_SRC="$try"; break; }
        done
        if [ -n "$ICON_SRC" ]; then
            cp "$ICON_SRC" "$STAGE/usr/share/APPLaunch/share/images/${BIN_NAME}.png"
        else
            echo "   NOTE: no icon found"
        fi
    fi

    echo "== staged payload =="
    find "$STAGE" -type f | sort

    # --- 3h. package ---
    PKG_FILE="$PKG_DIR/${PKG_NAME}-${VERSION}.tar.gz"
    rm -f "$PKG_FILE"
    tar -C "$STAGE" -czf "$PKG_FILE" .
    rm -rf "$STAGE"

    echo ""
    echo "== PACKAGE READY =="
    echo "   $(du -h "$PKG_FILE" | cut -f1)  $PKG_FILE"
    echo ""
    echo "$PKG_FILE"
    exit 0
fi

# ========================================================================
# 4. CMAKE / MAKE / SCONS path (C++ apps that need compilation)
# ========================================================================

# --- ensure build container ---
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
    echo "== reusing existing $CT =="
fi

# libcamera header fix (same as 26-apps.sh)
docker exec "$CT" sh -c '
if [ ! -e /usr/include/libcamera/camera.h ]; then
    cd /usr/include/libcamera 2>/dev/null || exit 0
    for f in libcamera/*; do ln -sfn "$f" "$(basename "$f")"; done
fi
true
'

SRC_IN_CT="/repo/build/apps-src/$REPO_NAME"
BUILD_DIR="build/cpz"

# --- fetch dependencies via fetch_repos.py ---
if docker exec "$CT" test -f "$SRC_IN_CT/fetch_repos.py" 2>/dev/null; then
    if docker exec "$CT" test ! -d "$SRC_IN_CT/dependencies/lvgl" 2>/dev/null; then
        echo "== fetching dependencies =="
        docker exec "$CT" sh -c "cd '$SRC_IN_CT' && python3 fetch_repos.py" \
            || echo "WARN: fetch_repos.py failed" >&2
    fi
fi

# --- version ---
VERSION=$(git -C "$SRC" describe --tags --always 2>/dev/null || echo "0.1.0")
VERSION="${VERSION#v}"
PKG_NAME="cpz-$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]')"

# --- build ---
echo "== building $PKG_NAME (ref: $CURRENT_REF) =="

if [ "$HAS_SCONS" -eq 1 ]; then
    docker exec "$CT" sh -c "set -e; cd '$SRC_IN_CT'; scons -j$JOBS"

elif [ "$HAS_CMAKE" -eq 1 ]; then
    CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release ${CPZ_CMAKE_FLAGS:-}"

    # Disable SDL/desktop/testing for native device builds
    docker exec "$CT" grep -qm1 'COMPASS_USE_SDL\|FILES_USE_SDL' \
        "$SRC_IN_CT/CMakeLists.txt" 2>/dev/null \
        && CMAKE_FLAGS="$CMAKE_FLAGS -DCOMPASS_USE_SDL=OFF -DFILES_USE_SDL=OFF -DFILES_USE_PULSEAUDIO=OFF"
    docker exec "$CT" grep -qm1 'option.*USE_DESKTOP' \
        "$SRC_IN_CT/CMakeLists.txt" 2>/dev/null \
        && CMAKE_FLAGS="$CMAKE_FLAGS -DUSE_DESKTOP=OFF"
    docker exec "$CT" grep -qm1 'BUILD_TESTING' \
        "$SRC_IN_CT/CMakeLists.txt" 2>/dev/null \
        && CMAKE_FLAGS="$CMAKE_FLAGS -DBUILD_TESTING=OFF"

    echo "   cmake flags: $CMAKE_FLAGS"
    docker exec "$CT" sh -c "
        set -e; cd '$SRC_IN_CT'
        cmake -S . -B '$BUILD_DIR' -G Ninja $CMAKE_FLAGS
        cmake --build '$BUILD_DIR' -j$JOBS
    "

elif [ "$HAS_MAKEFILE" -eq 1 ]; then
    docker exec "$CT" sh -c "set -e; cd '$SRC_IN_CT'; make -j$JOBS"

else
    cat >&2 <<HELP
ERROR: no supported build system found in $SRC.

Expected one of:
  app-builder.json  (metadata-driven Python / mixed app)
  CMakeLists.txt    (C++ app with CMake)
  Makefile          (generic Make-based project)
  SConstruct        (scons-based project)

The repo contains:
$(ls "$SRC" | head -20)
HELP
    exit 1
fi

# --- locate the binary ---
echo "== locating built binary =="
FOUND=$(docker exec "$CT" sh -c "
    cd '$SRC_IN_CT'
    tmp=\$(mktemp)
    for d in dist '${BUILD_DIR}' build; do
        [ -d \"\$d\" ] || continue
        find \"\$d\" -type f -executable 2>/dev/null | while read -r f; do
            file \"\$f\" 2>/dev/null | grep -q 'ARM aarch64' && echo \"\$f\" > \"\$tmp\"
        done
        if [ -s \"\$tmp\" ]; then cat \"\$tmp\"; rm -f \"\$tmp\"; exit 0; fi
    done
    rm -f \"\$tmp\"
" 2>/dev/null || true)

if [ -z "$FOUND" ]; then
    for guess in "dist/M5CardputerZero-$REPO_NAME" \
                 "${BUILD_DIR}/$REPO_NAME" \
                 "${BUILD_DIR}/${REPO_NAME}_app" \
                 "${BUILD_DIR}/camera_app" \
                 "dist/$REPO_NAME"; do
        docker exec "$CT" test -f "$SRC_IN_CT/$guess" 2>/dev/null && { FOUND="$guess"; break; }
    done
fi

[ -n "$FOUND" ] || die "cannot find built binary.  Set CPZ_BINARY_NAME=... and retry."
BINARY_BASENAME=$(basename "$FOUND")
echo "== binary: $FOUND =="
docker exec "$CT" sh -c "file '$SRC_IN_CT/$FOUND'"

# --- stage ---
mkdir -p "$STAGE/usr/share/APPLaunch/bin" \
         "$STAGE/usr/share/APPLaunch/applications" \
         "$STAGE/usr/share/APPLaunch/share/images"

docker cp "$CT:$SRC_IN_CT/$FOUND" "$STAGE/usr/share/APPLaunch/bin/$BINARY_BASENAME" \
    || die "cannot copy binary from container"
chmod 0755 "$STAGE/usr/share/APPLaunch/bin/$BINARY_BASENAME"

# .desktop files
docker exec "$CT" sh -c "cd '$SRC_IN_CT' && find . -name '*.desktop' -type f 2>/dev/null | head -10" \
    | while read -r df; do
        docker cp "$CT:$SRC_IN_CT/$df" \
            "$STAGE/usr/share/APPLaunch/applications/$(basename "$df")" 2>/dev/null || true
    done

if [ -z "$(ls -A "$STAGE/usr/share/APPLaunch/applications/" 2>/dev/null)" ]; then
    cat > "$STAGE/usr/share/APPLaunch/applications/${REPO_NAME}.desktop" <<DESKTOPDF
[Desktop Entry]
Type=Application
Name=$REPO_NAME
Exec=/usr/share/APPLaunch/bin/$BINARY_BASENAME
Icon=share/images/${PKG_NAME}.png
Terminal=false
Sysplause=false
DESKTOPDF
fi

# icon
ICON_OK=0
for pattern in "icon.png" "icon_100.png" "*_100.png" "app.png" "logo.png"; do
    docker exec "$CT" sh -c "
        cd '$SRC_IN_CT'
        find . -name '$pattern' -type f 2>/dev/null | grep -v node_modules | grep -v .git | head -3
    " | while read -r icon; do
        docker cp "$CT:$SRC_IN_CT/$icon" \
            "$STAGE/usr/share/APPLaunch/share/images/${PKG_NAME}.png" 2>/dev/null && touch "$STAGE/.icon-ok"
    done
    [ -f "$STAGE/.icon-ok" ] && { ICON_OK=1; rm -f "$STAGE/.icon-ok"; break; }
done
if [ "$ICON_OK" -eq 0 ]; then
    DEB_ICON="packaging/deb/images/$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]').png"
    docker exec "$CT" test -f "$SRC_IN_CT/$DEB_ICON" 2>/dev/null \
        && docker cp "$CT:$SRC_IN_CT/$DEB_ICON" "$STAGE/usr/share/APPLaunch/share/images/${PKG_NAME}.png" 2>/dev/null \
        && ICON_OK=1
fi
[ "$ICON_OK" -eq 0 ] && echo "NOTE: no icon found"

# asset dirs
for asset_dir in "assets" "fonts" "images" "audio"; do
    docker exec "$CT" test -d "$SRC_IN_CT/$asset_dir" 2>/dev/null || continue
    ASSET_DEST="$STAGE/usr/share/${PKG_NAME}"
    mkdir -p "$ASSET_DEST"
    docker exec "$CT" sh -c "cd '$SRC_IN_CT' && find '$asset_dir' -type f 2>/dev/null" \
        | while read -r af; do
            rel="${af#$SRC_IN_CT/}"
            mkdir -p "$ASSET_DEST/$(dirname "$rel")"
            docker cp "$CT:$af" "$ASSET_DEST/$rel" 2>/dev/null || true
        done
done

echo "== staged payload =="
find "$STAGE" -type f | sort
[ -f "$STAGE/usr/share/APPLaunch/bin/$BINARY_BASENAME" ] || die "binary missing from stage"

# --- package ---
PKG_FILE="$PKG_DIR/${PKG_NAME}-${VERSION}.tar.gz"
rm -f "$PKG_FILE"
tar -C "$STAGE" -czf "$PKG_FILE" .
rm -rf "$STAGE"

echo ""
echo "== PACKAGE READY =="
echo "   $(du -h "$PKG_FILE" | cut -f1)  $PKG_FILE"
echo ""
echo "$PKG_FILE"