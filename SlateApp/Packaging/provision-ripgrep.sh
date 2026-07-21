#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:?usage: provision-ripgrep.sh DESTINATION}"
# shellcheck disable=SC1091
source "$ROOT/SlateApp/Packaging/release-artifacts.env"

CACHE="$ROOT/.build/release-tools"
ARCHIVE="$CACHE/$RIPGREP_ARCHIVE"
EXTRACTED="$CACHE/ripgrep-$RIPGREP_VERSION-aarch64-apple-darwin/rg"
mkdir -p "$CACHE"

archive_is_valid() {
  [ -f "$ARCHIVE" ] && [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$RIPGREP_ARCHIVE_SHA256" ]
}

if ! archive_is_valid; then
  TMP="$(mktemp "$CACHE/.ripgrep-download.XXXXXX")"
  trap 'rm -f "$TMP"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    --output "$TMP" "$RIPGREP_URL"
  ACTUAL="$(shasum -a 256 "$TMP" | awk '{print $1}')"
  [ "$ACTUAL" = "$RIPGREP_ARCHIVE_SHA256" ] || {
    echo "ripgrep archive checksum mismatch" >&2
    exit 1
  }
  mv "$TMP" "$ARCHIVE"
  trap - EXIT
fi

if [ ! -x "$EXTRACTED" ]; then
  STAGE="$(mktemp -d "$CACHE/.ripgrep-extract.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  tar -xzf "$ARCHIVE" -C "$STAGE"
  rm -rf "$(dirname "$EXTRACTED")"
  mv "$STAGE/ripgrep-$RIPGREP_VERSION-aarch64-apple-darwin" "$(dirname "$EXTRACTED")"
  trap - EXIT
fi

file "$EXTRACTED" | grep -F "Mach-O 64-bit executable arm64" >/dev/null
"$EXTRACTED" --version | grep -F "ripgrep $RIPGREP_VERSION" >/dev/null
if otool -L "$EXTRACTED" | tail -n +2 | grep -E '/opt/homebrew|/usr/local|/Users/|/\.build/' >/dev/null; then
  echo "Pinned ripgrep binary contains a non-portable dependency" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp "$EXTRACTED" "$DEST"
chmod +x "$DEST"
