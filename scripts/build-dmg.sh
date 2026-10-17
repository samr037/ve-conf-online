#!/bin/bash
# Package and verify a local app. No installer, network or device operations.
set -euo pipefail
APP="${VEC_APP:?Set VEC_APP to the built application bundle}"
OUT="${VEC_DMG:?Set VEC_DMG to the output .dmg path}"
[[ -d "$APP" && "$OUT" == *.dmg ]] || { echo "Expected an app directory and .dmg output" >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vec-dmg.XXXXXX")"
MOUNT="$STAGE/mount"
cleanup() {
    if mount | grep -Fq " on $MOUNT "; then hdiutil detach "$MOUNT" -quiet || true; fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/content" "$(dirname "$OUT")" "$MOUNT"
ditto "$APP" "$STAGE/content/VE Configure.app"
ln -s /Applications "$STAGE/content/Applications"
hdiutil create -quiet -volname "VE Configure" -srcfolder "$STAGE/content" -format UDZO "$OUT"
hdiutil verify "$OUT"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$OUT"
codesign --verify --deep --strict "$MOUNT/VE Configure.app"
test "$(readlink "$MOUNT/Applications")" = /Applications
plutil -lint "$MOUNT/VE Configure.app/Contents/Info.plist"
lipo -archs "$MOUNT/VE Configure.app/Contents/MacOS/VEConfigure"
hdiutil detach "$MOUNT" -quiet
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Verified DMG: $OUT"
