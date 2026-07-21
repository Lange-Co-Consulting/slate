#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_ARG="${1:-}"
[[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
  echo "Usage: $0 <semver>" >&2; exit 1;
}

CURRENT_BUILD="$(tr -d '[:space:]' < BUILD_NUMBER)"
NEXT_BUILD="$((CURRENT_BUILD + 1))"
printf '%s\n' "$VERSION_ARG" > VERSION
printf '%s\n' "$NEXT_BUILD" > BUILD_NUMBER

echo "Slate $VERSION_ARG (build $NEXT_BUILD). Update CHANGELOG.md, verify, then tag v$VERSION_ARG."
