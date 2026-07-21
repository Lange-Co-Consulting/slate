#!/usr/bin/env bash
set -euo pipefail
# Build a release .app in a TEMP dir and install it as the ONE /Applications/Slate.app.
# Unlike build-dmg.sh this leaves NOTHING in the repo (no loose Slate.app that would
# register as a second "Slate" in Launchpad) and makes no DMG. Use for dev iteration.
cd "$(dirname "$0")/../.."   # -> repo root

echo "[deploy] verifying pinned native artifacts…"
bash SlateApp/Packaging/verify-native-artifacts.sh

echo "[deploy] building release binary (OWNER build: all Pro features unlocked)…"
# SLATE_PRO=1 links the private paid layer (../slate-pro); -DSLATE_OWNER then unlocks
# Pro for the operator's local app ONLY. A public clone has neither, so it builds the
# free app. The paid public DMG (build-dmg.sh) sets SLATE_PRO=1 but omits -DSLATE_OWNER,
# keeping the paywall live.
# --build-path .build-pro keeps the Pro build in its OWN dir: a plain `swift build` /
# `swift run SlateApp` (free) uses .build and can never pick up stale Pro artifacts.
SLATE_PRO=1 swift build -c release --disable-sandbox --build-path .build-pro -Xswiftc -DSLATE_OWNER
BIN=".build-pro/release/SlateApp"
test -f "$BIN" || { echo "[deploy] binary not found at $BIN"; exit 1; }
CLI=".build-pro/release/slatectl"
test -f "$CLI" || { echo "[deploy] CLI not found at $CLI"; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Slate.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Slate"
cp "$CLI" "$APP/Contents/Resources/slatectl"
chmod +x "$APP/Contents/Resources/slatectl"

# Embed llama.framework (linked via @rpath) + add the runtime rpath.
SLICE="$(ls -d Frameworks/llama.xcframework/macos-* | head -1)"
test -d "$SLICE/llama.framework" || { echo "[deploy] llama.framework slice not found"; exit 1; }
cp -R "$SLICE/llama.framework" "$APP/Contents/Frameworks/"

# MLX Metal kernels (Qwen3-TTS premium voice). SwiftPM cannot compile .metal
# shaders - this bundle is prebuilt ONCE via xcodebuild from the pinned
# mlx-swift revision (see Frameworks/README-mlx-metallib.md) and just copied.
if [ -d "Frameworks/mlx-swift_Cmlx.bundle" ]; then
  cp -R "Frameworks/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
fi
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Slate" 2>/dev/null || true

# Bundle the pinned portable ripgrep release rather than a local Homebrew copy.
bash SlateApp/Packaging/provision-ripgrep.sh "$APP/Contents/Resources/rg"

# App icon — always regenerate from gen-icon so it can't go stale.
bash SlateApp/Packaging/make-icns.sh || echo "[icns] regen failed — using existing"
[ -f "SlateApp/Packaging/Slate.icns" ] && cp "SlateApp/Packaging/Slate.icns" "$APP/Contents/Resources/Slate.icns"

cp SlateApp/Packaging/Info.plist "$APP/Contents/Info.plist"
SLATE_OWNER_BUILD=true bash SlateApp/Packaging/configure-plist.sh "$APP/Contents/Info.plist"
cp SlateApp/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R SlateApp/Help/Slate.help "$APP/Contents/Resources/"
[ -f THIRD_PARTY_NOTICES.md ] && cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
bash SlateApp/Packaging/collect-third-party-licenses.sh "$APP/Contents/Resources"
xcrun xcstringstool compile SlateApp/Localizable.xcstrings \
  --output-directory "$APP/Contents/Resources"

# Sign with a STABLE identity when one exists: ad-hoc (-) rotates the cdhash on
# every build, which silently drops the app's TCC grants (Microphone /
# Accessibility / Input Monitoring — everything Slate Flow needs) after each
# redeploy. Create the identity ONCE via Keychain Access → Certificate
# Assistant → Create a Certificate… → name "Slate Dev", type "Code Signing".
# A self-signed certificate has no Apple Team ID. Hardened Runtime library
# validation would then reject our embedded, independently signed llama.framework
# before Slate starts. The local-only entitlement keeps the remaining runtime
# protections while allowing that bundled framework. Developer ID releases keep
# the stricter standard entitlement file in build-dmg.sh.
LOCAL_ENTITLEMENTS="SlateApp/Packaging/Slate.local.entitlements"
# NB: `|| true` — under set -euo pipefail a no-match grep (exit 1) would kill
# the whole deploy right here, leaving the OLD bundle in /Applications.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Slate Dev[^"]*"' | head -1 | tr -d '"' || true)"
if [ -n "$IDENTITY" ]; then
  echo "[deploy] signing with stable identity: $IDENTITY"
  # A local self-signed "Slate Dev" identity cannot obtain an Apple timestamp.
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
  # Nested Mach-O tools must be signed individually (we avoid --deep): the
  # bundled ripgrep is otherwise left with its upstream ad-hoc signature, which
  # a future notarization run would reject.
  [ -f "$APP/Contents/Resources/rg" ] && codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/rg"
  codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/slatectl"
  codesign --force --options runtime --entitlements "$LOCAL_ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
else
  echo "[deploy] no 'Slate Dev' identity — ad-hoc signing (TCC grants reset each deploy; see comment above)"
  codesign --force --options runtime --sign - "$APP/Contents/Frameworks/llama.framework"
  [ -f "$APP/Contents/Resources/rg" ] && codesign --force --options runtime --sign - "$APP/Contents/Resources/rg"
  codesign --force --options runtime --sign - "$APP/Contents/Resources/slatectl"
  codesign --force --options runtime --entitlements "$LOCAL_ENTITLEMENTS" --sign - "$APP"
fi

bash SlateApp/Packaging/audit-app-bundle.sh "$APP" owner

# Replace the single installed copy. rm+cp unlinks the old inode, so this is safe
# even while Slate is running (the live process keeps its old inode until it quits).
rm -rf /Applications/Slate.app
cp -R "$APP" /Applications/Slate.app

# Ensure ONLY the /Applications copy exists AND is registered. build-dmg.sh (or a
# DMG the user mounted) can leave stray Slate.app copies that LaunchServices then
# offers as a SECOND "Slate" — self-heal every deploy: delete repo strays and
# unregister every Slate.app registration except /Applications.
rm -rf Slate.app                                 # never leave a second loose app
# Keep Slate.dmg: it is an inert release artifact, not a registered app copy.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  "$LSREG" -dump 2>/dev/null | grep -oE '/[^ ]*Slate\.app' | sort -u | while read -r p; do
    [ "$p" = "/Applications/Slate.app" ] || "$LSREG" -u "$p" >/dev/null 2>&1 || true
  done
  "$LSREG" -f /Applications/Slate.app >/dev/null 2>&1 || true
fi

echo "[deploy] installed -> /Applications/Slate.app  (only one Slate registered)"
