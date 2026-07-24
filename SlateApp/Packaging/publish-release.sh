#!/usr/bin/env bash
set -euo pipefail
# Publish a Slate release + the signed update manifest the in-app updater consumes.
#
# One command turns the current tree into a release the auto-updater can pick up:
#   1. builds the official DMG (SLATE_PRO release build, via build-dmg.sh)
#   2. computes its SHA256
#   3. signs an update manifest (appcast.json) with the pinned Ed25519 update key
#   4. verifies that manifest against the public key embedded in the app
#   5. creates a GitHub Release carrying BOTH the DMG and appcast.json
#
# The app's feed URL points at .../releases/latest/download/appcast.json, so the newest
# non-prerelease release is always what clients see. Version + build come from
# SlateApp/Packaging/Info.plist — bump them there before releasing.
#
# Free vs paid: the DMG here is the official (Pro-capable) build; Pro stays licence-gated
# at runtime. It is published to $SLATE_RELEASE_REPO (default: the public repo, so this
# works out of the box). Point that at a dedicated releases repo if you prefer to keep
# the paid binary off the open-source repo — the app's feed URL must match.
#
# Usage:
#   SlateApp/Packaging/publish-release.sh [notes-file]
# Env overrides:
#   SLATE_RELEASE_REPO   GitHub owner/repo for the release  (default: Lange-Co-Consulting/slate)
#   SLATE_UPDATE_KEY     path to the Ed25519 update private key
#   SLATE_RELEASE_DRAFT  set to 1 to create a draft release (nothing goes live until you publish)

cd "$(dirname "$0")/../.."   # -> repo root

REPO="${SLATE_RELEASE_REPO:-Lange-Co-Consulting/slate}"
KEY="${SLATE_UPDATE_KEY:-$HOME/Library/Application Support/Slate Release Keys/slate-beta-update.slatekey}"
PLIST="SlateApp/Packaging/Info.plist"
NOTES_FILE="${1:-}"

command -v gh >/dev/null || { echo "error: GitHub CLI (gh) is required." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: 'gh auth login' first." >&2; exit 1; }
[ -f "$KEY" ] || { echo "error: update key not found at: $KEY" >&2; exit 1; }

# VERSION/BUILD_NUMBER are the single source of truth (bump-version.sh writes them).
# The template Info.plist is only stamped into the *built* app by configure-plist.sh,
# so reading the version from it would publish under whatever the template last held —
# e.g. tagging a 1.0.0 build as v0.1.1 and clobbering that release's assets.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(tr -d '[:space:]' < BUILD_NUMBER)
PINNED_PUBKEY=$(/usr/libexec/PlistBuddy -c "Print :SlateUpdatePublicKey" "$PLIST")

# The paid layer must be licence-gated, never an owner build with everything unlocked.
if [ "${SLATE_OWNER_BUILD:-false}" = "true" ]; then
  echo "error: SLATE_OWNER_BUILD=true — that build unlocks every Pro feature. Never publish it." >&2
  exit 1
fi
TAG="v${VERSION}"
DMG="Slate.dmg"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG}"

# Fail fast if the signing key doesn't match the key pinned in the app (otherwise the
# app would silently reject every manifest this key produces).
DERIVED_PUBKEY=$(swift run SlateLicenseTool public-key --private-key "$KEY" 2>/dev/null | tail -1)
if [ "$DERIVED_PUBKEY" != "$PINNED_PUBKEY" ]; then
  echo "error: update key does not match the public key pinned in Info.plist." >&2
  echo "       pinned:  $PINNED_PUBKEY" >&2
  echo "       derived: $DERIVED_PUBKEY" >&2
  exit 1
fi

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
  NOTES="$(cat "$NOTES_FILE")"
else
  NOTES="Slate ${VERSION}."
fi

echo "[release] ${TAG} (build ${BUILD}) → ${REPO}"

echo "[release] building official DMG…"
bash SlateApp/Packaging/build-dmg.sh
[ -f "$DMG" ] || { echo "error: build-dmg.sh did not produce ${DMG}." >&2; exit 1; }

# A public release must be Developer-ID signed, notarized and stapled. Verify the
# actual artifact rather than trusting that the right env vars were exported —
# publishing an unnotarized DMG would give every downloader a Gatekeeper warning.
if [ "${SLATE_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
  echo "[release] WARNING: SLATE_ALLOW_UNNOTARIZED=1 — skipping notarization checks." >&2
  echo "[release] WARNING: do NOT hand this DMG to users." >&2
else
  echo "[release] verifying Developer ID signature, notarization and staple…"
  codesign --verify --strict --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'
  codesign -dvv "$DMG" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null || {
    echo "error: ${DMG} is not signed with a Developer ID Application certificate." >&2
    echo "       Run: bash SlateApp/Packaging/preflight-notarization.sh" >&2
    exit 1
  }
  xcrun stapler validate "$DMG" >/dev/null 2>&1 || {
    echo "error: ${DMG} has no stapled notarization ticket." >&2
    echo "       Rebuild with SLATE_NOTARY_PROFILE set (see preflight-notarization.sh)." >&2
    exit 1
  }
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'
  echo "[release] notarization verified ✓ (users get no Gatekeeper warning)"
fi

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "[release] sha256=${SHA}"

echo "[release] signing appcast.json…"
swift run SlateLicenseTool sign-update \
  --private-key "$KEY" \
  --version "$VERSION" --build "$BUILD" \
  --dmg-url "$DMG_URL" --sha256 "$SHA" \
  --minimum-os 26.0 \
  --notes "$NOTES" \
  --output appcast.json

# Independent verification against the SHIPPED public key — proves clients will accept it.
swift run SlateLicenseTool verify-update --public-key "$PINNED_PUBKEY" --input appcast.json
echo "[release] manifest verified against the pinned public key ✓"

DRAFT_FLAG=()
[ "${SLATE_RELEASE_DRAFT:-0}" = "1" ] && DRAFT_FLAG=(--draft)

echo "[release] creating GitHub release…"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  # Re-releasing the same tag: replace the two assets in place.
  gh release upload "$TAG" "$DMG" appcast.json --repo "$REPO" --clobber
  echo "[release] updated existing ${TAG}"
else
  # bash 3.2 (macOS) errors on an empty array under `set -u`; guard the expansion.
  gh release create "$TAG" "$DMG" appcast.json \
    --repo "$REPO" --title "Slate ${VERSION}" --notes "$NOTES" --latest ${DRAFT_FLAG[@]+"${DRAFT_FLAG[@]}"}
fi

echo "[release] done → https://github.com/${REPO}/releases/latest/download/appcast.json"