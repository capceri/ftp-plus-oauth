#!/bin/bash
# Packs an app into a drag-to-Applications disk image (macOS only).
#   scripts/make_dmg.sh "build/Dual Recorder.app" build/Dual-Recorder.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
OUT="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One background file holding both resolutions, so it's sharp on Retina screens.
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png -out "$WORK/background.tiff" >/dev/null

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet --disable-pip-version-check "dmgbuild>=1.6,<2"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$WORK/venv/bin/dmgbuild" -s scripts/dmg_settings.py \
    -D app="$APP" -D background="$WORK/background.tiff" -D icon=Resources/AppIcon.icns \
    "Dual Recorder" "$OUT"
echo "✓ Created $OUT"
