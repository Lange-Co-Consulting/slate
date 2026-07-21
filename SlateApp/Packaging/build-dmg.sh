#!/usr/bin/env bash
set -euo pipefail
# Build a real .app bundle around the SwiftPM release binary (no Xcode needed)
# and wrap it in a simple drag-to-Applications DMG (spec §3.6). The public
# path is the default. Internal co-founder builds require an explicit opt-in.
cd "$(dirname "$0")/../.."   # -> repo root

OWNER_BUILD="${SLATE_OWNER_BUILD:-false}"
[[ "$OWNER_BUILD" = "true" || "$OWNER_BUILD" = "false" ]] || {
  echo "SLATE_OWNER_BUILD must be true or false" >&2; exit 1;
}
DMG="Slate.dmg"
if [ "$OWNER_BUILD" = "true" ]; then
  DMG="Slate-Owner.dmg"
  echo "[dmg] INTERNAL OWNER BUILD: all Pro features are compiled in. Never publish this artifact."
fi

echo "[dmg] verifying pinned native artifacts…"
bash SlateApp/Packaging/verify-native-artifacts.sh

echo "[dmg] building release binary…"
# Both paths are the PAID app, so both link the private paid layer (SLATE_PRO=1).
# The free, open-source app is built by public cloners with a plain `swift build`
# (no SLATE_PRO, no ../slate-pro), never by this script.
if [ "$OWNER_BUILD" = "true" ]; then
  SLATE_PRO=1 swift build -c release --disable-sandbox --build-path .build-pro -Xswiftc -DSLATE_OWNER
else
  SLATE_PRO=1 swift build -c release --disable-sandbox --build-path .build-pro
fi

BIN=".build-pro/release/SlateApp"
test -f "$BIN" || { echo "[dmg] binary not found at $BIN"; exit 1; }
CLI=".build-pro/release/slatectl"
test -f "$CLI" || { echo "[dmg] CLI not found at $CLI"; exit 1; }

APP="Slate.app"
STAGE_ROOT=""
cleanup() {
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$LSREG" ] && [ -d "$APP" ] && "$LSREG" -u "$(pwd)/$APP" >/dev/null 2>&1 || true
  rm -rf "$APP"
  [ -n "$STAGE_ROOT" ] && rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Slate"
cp "$CLI" "$APP/Contents/Resources/slatectl"
chmod +x "$APP/Contents/Resources/slatectl"

# Embed llama.framework (the binary links it via @rpath) and add the runtime rpath.
SLICE="$(ls -d Frameworks/llama.xcframework/macos-* | head -1)"
test -d "$SLICE/llama.framework" || { echo "[dmg] llama.framework slice not found"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SLICE/llama.framework" "$APP/Contents/Frameworks/"

# MLX Metal kernels (Qwen3-TTS premium voice). SwiftPM cannot compile .metal
# shaders - this bundle is prebuilt ONCE via xcodebuild from the pinned
# mlx-swift revision (see Frameworks/README-mlx-metallib.md) and just copied.
if [ -d "Frameworks/mlx-swift_Cmlx.bundle" ]; then
  cp -R "Frameworks/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
fi
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Slate" 2>/dev/null || true

# Bundle the pinned portable ripgrep release; never copy a Homebrew binary with
# local dylib dependencies into a customer app.
bash SlateApp/Packaging/provision-ripgrep.sh "$APP/Contents/Resources/rg"

# App icon (graphite squircle + "Strata" mark). ALWAYS regenerate from gen-icon
# so the bundle icon can't go stale relative to the drawing code.
bash SlateApp/Packaging/make-icns.sh || echo "[icns] regen failed — using existing"
if [ -f "SlateApp/Packaging/Slate.icns" ]; then
  cp "SlateApp/Packaging/Slate.icns" "$APP/Contents/Resources/Slate.icns"
fi

cp SlateApp/Packaging/Info.plist "$APP/Contents/Info.plist"
SLATE_OWNER_BUILD="$OWNER_BUILD" bash SlateApp/Packaging/configure-plist.sh "$APP/Contents/Info.plist"
cp SlateApp/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R SlateApp/Help/Slate.help "$APP/Contents/Resources/"
[ -f THIRD_PARTY_NOTICES.md ] && cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
bash SlateApp/Packaging/collect-third-party-licenses.sh "$APP/Contents/Resources"
xcrun xcstringstool compile SlateApp/Localizable.xcstrings \
  --output-directory "$APP/Contents/Resources"

# Developer ID when configured; ad-hoc remains available for local test DMGs.
# A public release still needs notarization (see README.md).
IDENTITY="${SLATE_SIGN_IDENTITY:--}"
LOCAL_ENTITLEMENTS="SlateApp/Packaging/Slate.local.entitlements"
DEVELOPER_ID=false
# Nested Mach-O tools must each be signed (we avoid --deep): the bundled
# ripgrep otherwise keeps its upstream ad-hoc signature and notarization
# rejects it.
if [ "$IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - "$APP/Contents/Frameworks/llama.framework"
  [ -f "$APP/Contents/Resources/rg" ] && codesign --force --options runtime --sign - "$APP/Contents/Resources/rg"
  codesign --force --options runtime --sign - "$APP/Contents/Resources/slatectl"
  codesign --force --options runtime --entitlements "$LOCAL_ENTITLEMENTS" --sign - "$APP"
elif [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  # Local/self-signed certificates have no Apple Team ID. Keep the hardened
  # runtime, but allow our bundled third-party framework through validation.
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
  [ -f "$APP/Contents/Resources/rg" ] && codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/rg"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/slatectl"
  codesign --force --options runtime --entitlements "$LOCAL_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  DEVELOPER_ID=true
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
  [ -f "$APP/Contents/Resources/rg" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/rg"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/slatectl"
  codesign --force --timestamp --options runtime \
    --entitlements SlateApp/Slate.entitlements --sign "$IDENTITY" "$APP"
fi
if [ "$OWNER_BUILD" = "true" ]; then
  bash SlateApp/Packaging/audit-app-bundle.sh "$APP" owner
elif [ "$DEVELOPER_ID" = true ]; then
  bash SlateApp/Packaging/audit-app-bundle.sh "$APP" developer-id
else
  bash SlateApp/Packaging/audit-app-bundle.sh "$APP" public-test
fi

STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/Slate"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Slate" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
if [ "$DEVELOPER_ID" = true ]; then
  # DMGs use the Developer ID Application identity. Developer ID Installer is
  # for .pkg installers, not disk images.
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi

# Public release path: store credentials once with `xcrun notarytool store-credentials`
# and pass the profile name. Local builds omit this variable.
if [ -n "${SLATE_NOTARY_PROFILE:-}" ]; then
  if [ "$DEVELOPER_ID" != true ]; then
    echo "[dmg] SLATE_NOTARY_PROFILE requires a Developer ID identity" >&2
    exit 1
  fi
  echo "[dmg] notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$SLATE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  bash Scripts/make-update-manifest.sh "$DMG" build/update-beta.json
fi

echo "[dmg] done -> $(pwd)/$DMG  (no loose app left in the repo)"
