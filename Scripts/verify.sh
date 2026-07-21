#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

test -d Frameworks/llama.xcframework || {
  echo "Missing Frameworks/llama.xcframework" >&2
  exit 1
}
test -d Frameworks/sd.xcframework || {
  echo "Missing Frameworks/sd.xcframework" >&2
  exit 1
}

test -f THIRD_PARTY_NOTICES.md
test -f .github/dependabot.yml
test -f landing/privacy.html

plutil -lint SlateApp/Packaging/Info.plist
plutil -lint SlateApp/PrivacyInfo.xcprivacy
plutil -lint SlateApp/Slate.entitlements
jq empty SlateApp/Localizable.xcstrings
LOCALIZATION_DIR="$(mktemp -d)"
xcrun xcstringstool compile SlateApp/Localizable.xcstrings --output-directory "$LOCALIZATION_DIR"
rm -rf "$LOCALIZATION_DIR"
TEMP_PLIST="$(mktemp)"
cp SlateApp/Packaging/Info.plist "$TEMP_PLIST"
bash SlateApp/Packaging/configure-plist.sh "$TEMP_PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TEMP_PLIST")" = "$(tr -d '[:space:]' < VERSION)"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TEMP_PLIST")" = "$(tr -d '[:space:]' < BUILD_NUMBER)"
rm -f "$TEMP_PLIST"
swift build --product SlateApp --disable-sandbox
swift test --disable-sandbox

swift Scripts/generate-sbom.swift >/dev/null

echo "Slate verification passed."
