#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:?usage: collect-third-party-licenses.sh APP_RESOURCES_DIRECTORY}"
FLUID="$ROOT/.build/checkouts/FluidAudio"

test -f "$FLUID/LICENSE" || {
  echo "FluidAudio license not found; run swift package resolve before packaging" >&2
  exit 1
}
test -d "$FLUID/ThirdPartyLicenses" || {
  echo "FluidAudio third-party licenses not found" >&2
  exit 1
}

OUT="$DEST/ThirdPartyLicenses"
mkdir -p "$OUT"
cp "$ROOT"/Licenses/* "$OUT/"
cp "$FLUID/LICENSE" "$OUT/FluidAudio-Apache-2.0.txt"
cp "$FLUID/ThirdPartyLicenses/fastcluster-LICENSE.md" "$OUT/FluidAudio-fastcluster-BSD-3-Clause.md"
cp "$FLUID/ThirdPartyLicenses/vbx-LICENSE.md" "$OUT/FluidAudio-VBx-Apache-2.0.md"

test "$(find "$OUT" -type f | wc -l | tr -d '[:space:]')" -ge 8
