#!/usr/bin/env bash
set -euo pipefail
# Sync the curated public snapshot to github.com/Lange-Co-Consulting/slate.
#
# The public repo keeps its OWN clean history (no Pro source, no internal docs) and
# is intentionally disconnected from this private repo's full history. Run this from
# the private app repo root to publish the current tracked tree as the next public
# commit. Nothing here touches slate-pro (private) — a public clone can never resolve
# it (Package.swift links it only under SLATE_PRO=1, path-only).
#
#   Scripts/publish-public.sh ["commit message"]
#
# Excludes: docs/, CLAUDE.md, landing/ (deployed separately), Support/,
# Package.resolved (regenerated in the public clone), and the self-hosted
# .github/workflows/ci.yml (the hosted build.yml IS published for public CI).

PUBLIC_URL="https://github.com/Lange-Co-Consulting/slate.git"
MSG="${1:-Sync from private repo}"

cd "$(dirname "$0")/.."   # -> private repo root

WORK="$(mktemp -d)"; EXPORT="$(mktemp -d)"
trap 'rm -rf "$WORK" "$EXPORT"' EXIT

git clone -q "$PUBLIC_URL" "$WORK/pub"
git archive HEAD | tar -x -C "$EXPORT"
rm -rf "$EXPORT/docs" "$EXPORT/CLAUDE.md" "$EXPORT/landing" "$EXPORT/Support" "$EXPORT/Package.resolved" "$EXPORT/.github/workflows/ci.yml"

# Mirror the curated tree into the public clone (preserve its .git + Package.resolved).
rsync -a --delete --exclude='.git' --exclude='.build' --exclude='Package.resolved' "$EXPORT/" "$WORK/pub/"

cd "$WORK/pub"
# Refresh the pinned dependency graph against the current Package.swift.
swift package resolve >/dev/null 2>&1 || true
git add -A
if git diff --cached --quiet; then echo "[publish] public repo already up to date"; exit 0; fi
git commit -q -m "$MSG"
git push -q origin main
echo "[publish] pushed -> $PUBLIC_URL"
