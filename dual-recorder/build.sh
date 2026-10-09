#!/bin/bash
# Builds "Dual Recorder.app" and installs it in /Applications.
#
#   ./build.sh                build and install
#   ./build.sh --no-install   build only (the app is left in ./build)
#
# Needs Xcode or the Command Line Tools (xcode-select --install).
# The app is signed ad hoc by default. To sign with your own certificate instead, run e.g.
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Dual Recorder"
PRODUCT="DualRecorder"
APP="build/$APP_NAME.app"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Install the Command Line Tools with: xcode-select --install" >&2
    exit 1
fi

echo "▸ Compiling…"
swift build -c release --product "$PRODUCT"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing…"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"

if (( ! INSTALL )); then
    echo "✓ Built $APP"
    exit 0
fi

if pgrep -x "$PRODUCT" >/dev/null; then
    echo "Dual Recorder is running. Quit it first (stop and save any recording), then run ./build.sh again." >&2
    exit 1
fi

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
echo "▸ Installing to $DEST…"
rm -rf "$DEST/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"
echo "✓ Installed $DEST/$APP_NAME.app"
echo "  Open it with Spotlight (⌘-Space, \"Dual Recorder\") or: open \"$DEST/$APP_NAME.app\""
