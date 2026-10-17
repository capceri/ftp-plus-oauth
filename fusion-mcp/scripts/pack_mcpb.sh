#!/bin/bash
# Packs bridge/ into a Claude Desktop extension. A .mcpb file is a zip with manifest.json at its root.
#
#   scripts/pack_mcpb.sh [output.mcpb]     (default: build/fusion-essentials.mcpb)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/build/fusion-essentials.mcpb}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

rm -f "$out"
(cd "$here/bridge" && zip -q -X -r "$out" manifest.json server -x '*.DS_Store')
echo "$out"
