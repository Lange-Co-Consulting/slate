#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: audit-app-bundle.sh APP [owner|public-test|developer-id]}"
MODE="${2:-public-test}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "$MODE" in
  owner|public-test|developer-id) ;;
  *) echo "Unknown bundle-audit mode: $MODE" >&2; exit 1 ;;
esac

PLIST="$APP/Contents/Info.plist"
RES="$APP/Contents/Resources"
test -f "$PLIST"
plutil -lint "$PLIST" >/dev/null
codesign --verify --deep --strict --verbose=3 "$APP"

VERSION_VALUE="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_VALUE="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION_VALUE"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "$BUILD_VALUE"
# The channel must match what the build was configured with, not a hardcoded
# value — a stable release would otherwise fail its own audit.
EXPECTED_CHANNEL="${SLATE_RELEASE_CHANNEL:-stable}"
[[ "$EXPECTED_CHANNEL" = "beta" || "$EXPECTED_CHANNEL" = "stable" ]] || {
  echo "Invalid SLATE_RELEASE_CHANNEL: $EXPECTED_CHANNEL" >&2; exit 1;
}
test "$(/usr/libexec/PlistBuddy -c 'Print :SlateBuildChannel' "$PLIST")" = "$EXPECTED_CHANNEL"
# A public Developer ID build is a real release: it must never go out on the beta channel.
if [ "$MODE" = "developer-id" ] && [ "$EXPECTED_CHANNEL" != "stable" ]; then
  echo "Public Developer ID release must be built with SLATE_RELEASE_CHANNEL=stable" >&2
  exit 1
fi

OWNER_VALUE="$(/usr/libexec/PlistBuddy -c 'Print :SlateOwnerBuild' "$PLIST")"
if [ "$MODE" = "owner" ]; then
  test "$OWNER_VALUE" = "true"
else
  test "$OWNER_VALUE" = "false"
fi

UPDATE_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SlateUpdatePublicKey' "$PLIST")"
UPDATE_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SlateUpdateFeedURL' "$PLIST")"
[[ "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]
[[ "$UPDATE_FEED" =~ ^https://[^[:space:]@]+$ ]]

test -f "$RES/PrivacyInfo.xcprivacy"
test -f "$RES/THIRD_PARTY_NOTICES.md"
test -d "$RES/ThirdPartyLicenses"
test "$(find "$RES/ThirdPartyLicenses" -type f | wc -l | tr -d '[:space:]')" -ge 8
test -f "$RES/de.lproj/Localizable.strings"
test -f "$RES/Slate.help/Contents/Resources/en.lproj/index.html"
test -f "$RES/Slate.help/Contents/Resources/de.lproj/index.html"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookFolder' "$PLIST")" = "Slate.help"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleHelpBookName' "$PLIST")" = "com.langeundco.slate.help"
plutil -lint "$RES/Slate.help/Contents/Info.plist" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$PLIST")" = "en"
test -x "$RES/rg"
test -x "$RES/slatectl"
"$RES/rg" --version | grep -F "ripgrep 15.1.0" >/dev/null

ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign -d --entitlements "$ENTITLEMENTS" "$APP" 2>/dev/null
for forbidden in com.apple.security.get-task-allow \
                 com.apple.security.cs.allow-jit \
                 com.apple.security.cs.allow-unsigned-executable-memory; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Forbidden entitlement in bundle: $forbidden" >&2
    exit 1
  fi
done
if [ "$MODE" = "developer-id" ] && \
   /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS" >/dev/null 2>&1; then
  echo "Public bundle disables library validation" >&2
  exit 1
fi

while IFS= read -r binary; do
  codesign --verify --strict --verbose=2 "$binary"
  if otool -L "$binary" | tail -n +2 | grep -E '/opt/homebrew|/usr/local|/Users/|/\.build/' >/dev/null; then
    echo "Non-portable dynamic dependency in $binary" >&2
    exit 1
  fi
done < <(find "$APP/Contents" -type f -perm -111 -print)

if [ "$MODE" = "developer-id" ]; then
  APP_DETAILS="$(codesign -dvv "$APP" 2>&1)"
  echo "$APP_DETAILS" | grep -F 'Authority=Developer ID Application:' >/dev/null
  TEAM="$(echo "$APP_DETAILS" | awk -F= '/^TeamIdentifier=/{print $2}')"
  test -n "$TEAM" && test "$TEAM" != "not set"
  echo "$APP_DETAILS" | grep -F 'Timestamp=' >/dev/null
  while IFS= read -r binary; do
    DETAILS="$(codesign -dvv "$binary" 2>&1)"
    echo "$DETAILS" | grep -F "TeamIdentifier=$TEAM" >/dev/null
    echo "$DETAILS" | grep -F 'Timestamp=' >/dev/null
  done < <(find "$APP/Contents" -type f -perm -111 -print)
fi

echo "App bundle audit passed ($MODE)."
