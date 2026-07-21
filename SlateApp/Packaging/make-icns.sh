#!/bin/bash
# Regenerate SlateApp/Packaging/Slate.icns from gen-icon.swift (the Strata mark),
# as a proper multi-resolution .icns. Run by build-dmg.sh so the app icon can
# never go stale relative to the drawing code.
set -euo pipefail
cd "$(dirname "$0")/../.."          # repo root

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
M="$TMP/icon1024.png"
# Keep the standalone Swift invocation isolated from SwiftPM's module cache.
# On macOS /tmp resolves to /private/tmp; reusing a caller-provided cache can
# otherwise make Clang see the same PCM through both paths and abort.
swift -module-cache-path "$TMP/module-cache" \
  SlateApp/Packaging/gen-icon.swift "$M" >/dev/null

IS="$TMP/Slate.iconset"; mkdir -p "$IS"
sips -z 16 16   "$M" --out "$IS/icon_16x16.png"      >/dev/null
sips -z 32 32   "$M" --out "$IS/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$M" --out "$IS/icon_32x32.png"      >/dev/null
sips -z 64 64   "$M" --out "$IS/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$M" --out "$IS/icon_128x128.png"    >/dev/null
sips -z 256 256 "$M" --out "$IS/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$M" --out "$IS/icon_256x256.png"    >/dev/null
sips -z 512 512 "$M" --out "$IS/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$M" --out "$IS/icon_512x512.png"    >/dev/null
cp "$M" "$IS/icon_512x512@2x.png"
iconutil -c icns "$IS" -o SlateApp/Packaging/Slate.icns
echo "[icns] regenerated SlateApp/Packaging/Slate.icns"
