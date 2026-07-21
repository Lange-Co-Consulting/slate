#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source SlateApp/Packaging/release-artifacts.env

verify_hash() {
  local path="$1" expected="$2" actual
  test -f "$path" || { echo "Missing release artifact: $path" >&2; exit 1; }
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "Release artifact checksum mismatch: $path" >&2
    echo "expected $expected" >&2
    echo "actual   $actual" >&2
    exit 1
  fi
}

verify_hash "$LLAMA_BINARY_PATH" "$LLAMA_BINARY_SHA256"
verify_hash "$LLAMA_INFO_PATH" "$LLAMA_INFO_SHA256"
verify_hash "$SD_LIBRARY_PATH" "$SD_LIBRARY_SHA256"
verify_hash "$SD_INFO_PATH" "$SD_INFO_SHA256"
verify_hash "$SD_HEADER_PATH" "$SD_HEADER_SHA256"

plutil -lint "$LLAMA_INFO_PATH" "$SD_INFO_PATH" >/dev/null
file "$LLAMA_BINARY_PATH" | grep -F "Mach-O universal binary" >/dev/null
lipo -archs "$LLAMA_BINARY_PATH" | grep -F "arm64" >/dev/null
file "$SD_LIBRARY_PATH" | grep -F "current ar archive" >/dev/null

if otool -L "$LLAMA_BINARY_PATH" | grep -E '/opt/homebrew|/usr/local|/Users/|/\.build/' >/dev/null; then
  echo "llama.framework contains a non-portable dynamic dependency" >&2
  exit 1
fi

echo "Pinned native artifacts verified."
