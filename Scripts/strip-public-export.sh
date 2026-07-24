#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <temporary-export-directory>" >&2
  exit 64
fi

EXPORT_ROOT="$(cd "$1" && pwd -P)"
if [[ "$EXPORT_ROOT" == "/" || "$EXPORT_ROOT" == "$HOME" || -z "$EXPORT_ROOT" ]]; then
  echo "refusing unsafe export directory: $EXPORT_ROOT" >&2
  exit 65
fi

PRIVATE_PATHS=(
  "docs"
  "CLAUDE.md"
  "landing"
  "Admin"
  "Support"
  "Package.resolved"
  ".github/workflows/ci.yml"
  # Internal legal-readiness risk register (open items, trademark/counsel to-dos).
  # It stays honest in the private repo; publishing an internal risk log is not
  # something a shipped product should do.
  "COMPLIANCE.md"
)

for relative_path in "${PRIVATE_PATHS[@]}"; do
  rm -rf "$EXPORT_ROOT/$relative_path"
done
