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
# The COMMITTED template must already match VERSION/BUILD_NUMBER. Checking only the
# configure-plist.sh output would be tautological — that script writes those very
# values — which is how the template silently drifted a release behind before.
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' SlateApp/Packaging/Info.plist)" = "$(tr -d '[:space:]' < VERSION)" \
  || { echo "SlateApp/Packaging/Info.plist version != VERSION — run Scripts/bump-version.sh" >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' SlateApp/Packaging/Info.plist)" = "$(tr -d '[:space:]' < BUILD_NUMBER)" \
  || { echo "SlateApp/Packaging/Info.plist build != BUILD_NUMBER — run Scripts/bump-version.sh" >&2; exit 1; }
TEMP_PLIST="$(mktemp)"
cp SlateApp/Packaging/Info.plist "$TEMP_PLIST"
bash SlateApp/Packaging/configure-plist.sh "$TEMP_PLIST"
test "$(/usr/libexec/PlistBuddy -c 'Print :SlateBuildChannel' "$TEMP_PLIST")" = "${SLATE_RELEASE_CHANNEL:-stable}"
rm -f "$TEMP_PLIST"
swift build --product SlateApp --disable-sandbox
# The app package has no test target of its own — the suites live in slate-engine
# (348 tests) and slate-ui. Running `swift test` here always failed with "no tests
# found", which silently made release-check.sh unpassable. Run them only if a target
# is ever added, and say so either way.
if grep -q 'testTarget' Package.swift; then
  swift test --disable-sandbox
else
  echo "verify: no test target in this package — engine/UI suites run in their own repos."
fi

swift Scripts/generate-sbom.swift >/dev/null

echo "Slate verification passed."
