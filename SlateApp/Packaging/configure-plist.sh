#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$1"
VERSION="${SLATE_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD="${SLATE_BUILD_NUMBER:-$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER")}"
CHANNEL="${SLATE_RELEASE_CHANNEL:-beta}"
OWNER_BUILD="${SLATE_OWNER_BUILD:-false}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "Invalid Slate version: $VERSION" >&2; exit 1;
}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid Slate build number: $BUILD" >&2; exit 1;
}
[[ "$CHANNEL" = "beta" || "$CHANNEL" = "stable" ]] || {
  echo "Invalid Slate release channel: $CHANNEL" >&2; exit 1;
}
[[ "$OWNER_BUILD" = "true" || "$OWNER_BUILD" = "false" ]] || {
  echo "SLATE_OWNER_BUILD must be true or false" >&2; exit 1;
}

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SlateBuildChannel $CHANNEL" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SlateOwnerBuild $OWNER_BUILD" "$PLIST"

# Public Ed25519 verifier only. The private signing key must never enter the app,
# build environment, repository, CI artefacts or release bundle.
if [[ -n "${SLATE_OFFLINE_LICENSE_PUBLIC_KEY:-}" ]]; then
  [[ "$SLATE_OFFLINE_LICENSE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "Invalid SLATE_OFFLINE_LICENSE_PUBLIC_KEY (expected base64 Ed25519 public key)" >&2; exit 1;
  }
  /usr/libexec/PlistBuddy -c "Set :SlateOfflineLicensePublicKey $SLATE_OFFLINE_LICENSE_PUBLIC_KEY" "$PLIST"
fi

# Update manifests are independently signed. Empty means self-update is
# deliberately disabled (safe for development/ad-hoc builds).
if [[ -n "${SLATE_UPDATE_PUBLIC_KEY:-}" ]]; then
  [[ "$SLATE_UPDATE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "Invalid SLATE_UPDATE_PUBLIC_KEY (expected base64 Ed25519 public key)" >&2; exit 1;
  }
  /usr/libexec/PlistBuddy -c "Set :SlateUpdatePublicKey $SLATE_UPDATE_PUBLIC_KEY" "$PLIST"
fi

if [[ -n "${SLATE_UPDATE_FEED_URL:-}" ]]; then
  [[ "$SLATE_UPDATE_FEED_URL" =~ ^https://[^[:space:]@]+$ ]] || {
    echo "Invalid SLATE_UPDATE_FEED_URL (expected credential-free HTTPS URL)" >&2; exit 1;
  }
  /usr/libexec/PlistBuddy -c "Set :SlateUpdateFeedURL $SLATE_UPDATE_FEED_URL" "$PLIST"
fi
