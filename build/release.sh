#!/bin/sh
# build/release.sh — package a flashable CPZ-Alpine GitHub release.
#
# Usage: sh build/release.sh X.Y.Z
#
# Produces images/cpz-alpine-X.Y.Z.zip with this layout:
#
#   cpz-alpine-X.Y.Z/
#     cpz-alpine-X.Y.Z.img.gz
#     cpz-alpine-X.Y.Z.img.gz.sha256
#     flash-cpz.sh
#     flash-cpz.bat
#     flash-cpz.ps1
#     flash-cpz.command
#     README.txt
#     RELEASE-NOTES.txt
#
# plus images/cpz-alpine-X.Y.Z.zip.sha256. Upload both to the GitHub
# release (see the Releases section in AGENTS.md); never commit them.
set -eu

VER=${1:?usage: sh build/release.sh X.Y.Z}
REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$REPO"

IMG="images/cpz-alpine-$VER.img.gz"
IMG_SHA="$IMG.sha256"
NOTES="docs/RELEASE-NOTES-v$VER.md"
TEMPLATE="docs/RELEASE-README.txt"
ASSETS="build/release-assets"
STAGE="build/release-stage/cpz-alpine-$VER"
ZIP="images/cpz-alpine-$VER.zip"

[ -f "$IMG" ] || { echo "ERROR: $IMG missing — build the image first"; exit 1; }
[ -f "$IMG_SHA" ] || { echo "ERROR: $IMG_SHA missing"; exit 1; }
[ -f "$NOTES" ] || { echo "ERROR: $NOTES missing — write the release notes"; exit 1; }
[ -f "$TEMPLATE" ] || { echo "ERROR: $TEMPLATE missing"; exit 1; }
grep -q "^VER=$VER$" build/30-image.sh \
    || { echo "ERROR: build/30-image.sh VER is not $VER"; exit 1; }
grep -q "^VERSION=\"$VER\"$" rootfs-overlay/etc/cpz-release \
    || { echo "ERROR: cpz-release VERSION is not $VER"; exit 1; }

SHA=$(cut -d' ' -f1 "$IMG_SHA")
DATE=$(date -u +%Y-%m-%d)

echo "== staging $STAGE =="
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$IMG" "$IMG_SHA" "$STAGE/"
cp build/flash-cpz.sh "$STAGE/"
cp "$ASSETS/flash-cpz.bat" "$ASSETS/flash-cpz.ps1" "$ASSETS/flash-cpz.command" "$STAGE/"
cp "$NOTES" "$STAGE/RELEASE-NOTES.txt"

sed -e "s/@VERSION@/$VER/g" -e "s/@SHA256@/$SHA/g" -e "s/@DATE@/$DATE/g" \
    "$TEMPLATE" > "$STAGE/README.txt"

chmod 755 "$STAGE/flash-cpz.sh" "$STAGE/flash-cpz.command"
chmod 644 "$STAGE/README.txt" "$STAGE/RELEASE-NOTES.txt" \
    "$STAGE/cpz-alpine-$VER.img.gz" "$STAGE/cpz-alpine-$VER.img.gz.sha256"
chmod 644 "$STAGE/flash-cpz.bat" "$STAGE/flash-cpz.ps1"

# Windows cmd/PowerShell tools are happiest with CRLF.
perl -pi -e 's/\r?\n/\r\n/' "$STAGE/flash-cpz.bat" "$STAGE/flash-cpz.ps1"

echo "== creating $ZIP =="
rm -f "$ZIP" "$ZIP.sha256"
docker exec cpz-builder sh -c \
    "cd /repo/build/release-stage && zip -q -r -X /repo/$ZIP cpz-alpine-$VER"
docker exec cpz-builder sh -c "unzip -l /repo/$ZIP" | tail -14
( cd images && sha256sum "cpz-alpine-$VER.zip" > "cpz-alpine-$VER.zip.sha256" )

echo
echo "== release package ready =="
ls -lh "$ZIP" "$ZIP.sha256"
echo
echo "Next: commit + push, then upload the ZIP and .sha256 to GitHub:"
echo "  gh release create v$VER --repo kkazakov/cardputer-zero-alpine-linux \\"
echo "    --target main --title 'CPZ-Alpine v$VER' \\"
echo "    --notes-file $NOTES \\"
echo "    $ZIP $ZIP.sha256"