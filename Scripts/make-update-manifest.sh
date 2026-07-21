#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DMG="${1:-Slate.dmg}"
OUTPUT="${2:-build/update-beta.json}"
PRIVATE_KEY="${SLATE_UPDATE_PRIVATE_KEY:-$HOME/Library/Application Support/Slate Release Keys/slate-beta-update.slatekey}"
VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
BUILD_VALUE="$(tr -d '[:space:]' < BUILD_NUMBER)"
DMG_URL="${SLATE_DMG_URL:-https://slate-app.org/downloads/Slate-$VERSION_VALUE-beta-$BUILD_VALUE.dmg}"
NOTES="${SLATE_UPDATE_NOTES:-Slate $VERSION_VALUE Beta build $BUILD_VALUE}"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SlateUpdatePublicKey' SlateApp/Packaging/Info.plist)"

test -f "$DMG" || { echo "DMG not found: $DMG" >&2; exit 1; }
test -f "$PRIVATE_KEY" || { echo "Update private key not found: $PRIVATE_KEY" >&2; exit 1; }
[[ "$DMG_URL" =~ ^https://[^[:space:]@]+$ ]] || {
  echo "SLATE_DMG_URL must be a credential-free HTTPS URL" >&2; exit 1;
}

mkdir -p "$(dirname "$OUTPUT")"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
swift run --disable-sandbox SlateLicenseTool sign-update \
  --private-key "$PRIVATE_KEY" \
  --version "$VERSION_VALUE" \
  --build "$BUILD_VALUE" \
  --dmg-url "$DMG_URL" \
  --sha256 "$SHA256" \
  --output "$OUTPUT" \
  --notes "$NOTES" \
  --minimum-os 26.0
swift run --disable-sandbox SlateLicenseTool verify-update \
  --public-key "$PUBLIC_KEY" --input "$OUTPUT"

echo "Upload $DMG to $DMG_URL and $OUTPUT to the beta feed URL only after notarization."
