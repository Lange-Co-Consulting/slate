#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
BUILD_VALUE="$(tr -d '[:space:]' < BUILD_NUMBER)"

grep -F "[$VERSION_VALUE]" CHANGELOG.md >/dev/null || {
  echo "CHANGELOG.md has no [$VERSION_VALUE] section" >&2
  exit 1
}

test -n "$BUILD_VALUE"
bash -n Scripts/*.sh SlateApp/Packaging/*.sh
git diff --check
bash Scripts/verify-license-inventory.sh
bash SlateApp/Packaging/verify-native-artifacts.sh
swift Scripts/generate-sbom.swift
./Scripts/verify.sh

echo "Release checks passed for Slate $VERSION_VALUE ($BUILD_VALUE)."
echo "Developer ID signing, notarization, stapling and public download verification remain operator steps."
