#!/bin/zsh
# Build Halation.app and install it into ~/Applications.
set -e
cd "$(dirname "$0")"

swift build -c release

APP_DIR="$HOME/Applications"
APP="$APP_DIR/Halation.app"
mkdir -p "$APP_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Halation "$APP/Contents/MacOS/Halation"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"

# Let LaunchServices know about us (enables "Open With > Halation").
# A plain -f sometimes leaves a stale record without the document-type
# claims, so do a full unregister/re-register cycle.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -f -u "$APP" || true
"$LSREGISTER" -f "$APP" || true

echo "Built and installed: $APP"
