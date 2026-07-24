#!/usr/bin/env bash
set -euo pipefail
# Verify everything Apple-gated BEFORE a long release build, so a missing
# certificate or notary credential fails in seconds instead of after the build.
#
#   bash SlateApp/Packaging/preflight-notarization.sh [notary-profile]
#
# Exits 0 only when a notarized public release can actually be produced.
# Prints the exact SLATE_SIGN_IDENTITY to use.

PROFILE="${1:-${SLATE_NOTARY_PROFILE:-slate-notary}}"
FAIL=0

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }

echo "Slate — notarization preflight"
echo

# 1) Xcode command line tools -----------------------------------------------
echo "[1/4] Toolchain"
if xcrun --find notarytool >/dev/null 2>&1; then
  ok "notarytool present ($(xcrun --find notarytool))"
else
  bad "notarytool not found — install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
fi
if xcrun --find stapler >/dev/null 2>&1; then
  ok "stapler present"
else
  bad "stapler not found (comes with Xcode)"
fi
echo

# 2) Developer ID Application certificate ------------------------------------
echo "[2/4] Developer ID Application certificate"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEV_ID_LINE="$(printf '%s\n' "$IDENTITIES" | grep -F 'Developer ID Application:' | head -1 || true)"
if [ -n "$DEV_ID_LINE" ]; then
  # Extract the quoted identity name.
  DEV_ID="$(printf '%s\n' "$DEV_ID_LINE" | sed -n 's/.*"\(.*\)".*/\1/p')"
  ok "found: $DEV_ID"
  export SLATE_SIGN_IDENTITY="$DEV_ID"
else
  bad "no 'Developer ID Application' certificate in the keychain"
  note ""
  note "  Create it once (needs the Lange & Co. Apple ID):"
  note "    Xcode ▸ Settings ▸ Accounts ▸ (+) Apple ID ▸ sign in"
  note "    ▸ Manage Certificates ▸ (+) ▸ Developer ID Application"
  note ""
  note "  Self-signed identities present right now:"
  printf '%s\n' "$IDENTITIES" | sed 's/^/      /'
fi
echo

# 3) notarytool credentials ---------------------------------------------------
echo "[3/4] Notary credentials (keychain profile: $PROFILE)"
if [ -z "${DEV_ID:-}" ]; then
  note "skipped — needs the certificate first"
elif xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ok "profile '$PROFILE' works (Apple accepted the credentials)"
else
  bad "no working notary profile named '$PROFILE'"
  note ""
  note "  Store it once (app-specific password from appleid.apple.com"
  note "  ▸ Sign-In & Security ▸ App-Specific Passwords):"
  note "    xcrun notarytool store-credentials \"$PROFILE\" \\"
  note "      --apple-id \"<your-apple-id>\" \\"
  note "      --team-id \"<TEAM_ID>\" \\"
  note "      --password \"<app-specific-password>\""
fi
echo

# 4) Release inputs -----------------------------------------------------------
echo "[4/4] Release inputs"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")"
ok "version $VERSION (build $BUILD)"
if grep -F "[$VERSION]" "$ROOT/CHANGELOG.md" >/dev/null 2>&1; then
  ok "CHANGELOG has a [$VERSION] section"
else
  bad "CHANGELOG.md has no [$VERSION] section"
fi
if [ -d "$ROOT/../slate-pro" ]; then
  ok "slate-pro present (paid layer will be linked)"
else
  bad "../slate-pro missing — the public DMG must be built with the paid layer"
fi
echo

if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
Preflight passed. Build the notarized DMG with:

  SLATE_RELEASE_CHANNEL=stable \\
  SLATE_SIGN_IDENTITY="$DEV_ID" \\
  SLATE_NOTARY_PROFILE="$PROFILE" \\
  bash SlateApp/Packaging/build-dmg.sh
EOF
  exit 0
fi

echo "Preflight FAILED — fix the ✗ items above before releasing." >&2
exit 1
