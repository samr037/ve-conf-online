#!/bin/sh
# Builds and installs ~/Applications/VE Configure.app (ad-hoc signed).
# Build outside ~/Claude (sync breaks build.db).
# VEC_CONFIG=debug installs a debug build, which keeps the --capture/--snapshot design-review hooks.
set -e
cd "$(dirname "$0")/.."
BUILD="${VEC_BUILD:-/tmp/vec-build}"
APP="${VEC_APP:-$HOME/Applications/VE Configure.app}"
CONFIG="${VEC_CONFIG:-release}"
case "$CONFIG" in release|debug) ;; *) echo "VEC_CONFIG must be release or debug" >&2; exit 1 ;; esac
# Refuse anything that is not an .app bundle path before the rm -rf below.
case "$APP" in
  .app|*/.app) echo "Refusing to replace '$APP': no bundle name" >&2; exit 1 ;;
  *.app) ;;
  *) echo "Refusing to replace '$APP': VEC_APP must end with .app" >&2; exit 1 ;;
esac
swift build -c "$CONFIG" --product VEConfigure --scratch-path "$BUILD"
BIN="$(swift build -c "$CONFIG" --product VEConfigure --scratch-path "$BUILD" --show-bin-path)/VEConfigure"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Sources/VEConfigure/Resources/catalog.json Sources/VEConfigure/Resources/catalog-strings.json "$APP/Contents/Resources/"
for l in Resources/*.lproj; do [ -e "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done
cp "$BIN" "$APP/Contents/MacOS/VEConfigure"
codesign --force --sign - --identifier local.veconfigure.mac "$APP"
codesign --verify "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed ($CONFIG): $APP"
