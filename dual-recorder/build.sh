#!/bin/bash
# Builds "Dual Recorder.app" and installs it in /Applications.
#
#   ./build.sh                build and install
#   ./build.sh --no-install   build only (the app is left in ./build)
#
# Needs Xcode or the Command Line Tools (xcode-select --install).
# The app is signed ad hoc by default. To sign with your own certificate instead, run e.g.
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#
# Optional settings (used by scripts/release.sh):
#   UNIVERSAL=1          build for Apple Silicon and Intel (needs full Xcode)
#   VERSION=1.2.0        version shown in Finder and About
#   BUILD_NUMBER=42      internal build number
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

ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling…"
swift build -c release --product "$PRODUCT" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${SIGN_IDENTITY:--}"
echo "▸ Signing ($([[ "$IDENTITY" == "-" ]] && echo "ad hoc" || echo "$IDENTITY"))…"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi

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
