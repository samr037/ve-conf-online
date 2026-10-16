#!/bin/sh
# Builds and installs ~/Applications/VE Configure.app (ad-hoc signed).
# Build outside ~/Claude (sync breaks build.db).
set -e
cd "$(dirname "$0")/.."
BUILD="${VEC_BUILD:-/tmp/vec-build}"
APP="${VEC_APP:-$HOME/Applications/VE Configure.app}"
swift build -c release --product VEConfigure --scratch-path "$BUILD"
BIN="$(swift build -c release --product VEConfigure --scratch-path "$BUILD" --show-bin-path)/VEConfigure"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Sources/VEConfigure/Resources/catalog.json "$APP/Contents/Resources/"
for l in Resources/*.lproj; do [ -e "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done
cp "$BIN" "$APP/Contents/MacOS/VEConfigure"
codesign --force --sign - --identifier local.veconfigure.mac "$APP"
codesign --verify "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed: $APP"
