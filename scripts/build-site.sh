#!/usr/bin/env bash
#
# Full site build. Chains the two Swift generators that produce data
# the Eleventy templates need, then runs Eleventy.
#
# Run from the repo root:
#   bash scripts/build-site.sh
#
# Or via the bun script wrapper:
#   bun run site:full
#
# Order matters:
#   1. build-cable-db.swift writes docs/whatcable.db and docs/cables.json
#      from data/known-cables.md + Sources/.../usbif-vendors.tsv.
#   2. render-known-cables.swift parses data/known-cables.md and writes
#      src/_includes/cables-table.njk (the noscript fallback table).
#   3. Eleventy reads src/ and writes docs/, including cables.njk which
#      includes the table partial from step 2.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=> Building cable database..."
swift scripts/build-cable-db.swift

echo ""
echo "=> Rendering cables table partial..."
swift scripts/render-known-cables.swift

echo ""
echo "=> Building site with Eleventy..."
bun run site:build

echo ""
echo "=> Copying blog post assets..."
# Each post in src/blog/posts/ can have a sibling folder of the same
# slug (with date prefix) holding images and other assets. We copy
# those into docs/blog/<slug>/ with the date prefix stripped so the
# URL matches the rendered post URL.
#
# Example layout:
#   src/blog/posts/2026-06-01-tb5-deep-dive.md
#   src/blog/posts/2026-06-01-tb5-deep-dive/
#     diagram.webp
#   -> docs/blog/tb5-deep-dive/diagram.webp
#
# Reference in markdown as /blog/tb5-deep-dive/diagram.webp.
shopt -s nullglob
copied=0
for asset_dir in src/blog/posts/*/; do
  dir_name="${asset_dir%/}"
  dir_name="${dir_name##*/}"
  slug="${dir_name#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
  if [ "$slug" = "$dir_name" ]; then
    echo "  skipping $dir_name (no YYYY-MM-DD- prefix)"
    continue
  fi
  mkdir -p "docs/blog/$slug"
  for asset in "$asset_dir"*; do
    [ -f "$asset" ] || continue
    cp "$asset" "docs/blog/$slug/"
    copied=$((copied + 1))
  done
done
echo "  $copied asset(s) copied"

echo ""
echo "Site build complete. Output in docs/."
