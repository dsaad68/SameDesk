#!/usr/bin/env bash
#
# Compile the Icon Composer source (docs/icon.icon — a Liquid Glass app icon)
# into the artifacts the .app bundle ships:
#
#   Resources/AppIcon.icns   composed raster, per-size (universal fallback)
#   Resources/Assets.car     compiled asset catalog (live Liquid Glass on macOS 26)
#
# make-app.sh copies both into the bundle and sets CFBundleIconFile +
# CFBundleIconName. Re-run this after editing docs/icon.icon in Icon Composer.
#
# Requires Xcode's actool (Xcode 26+ to understand the .icon format).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/icon.icon"
OUT="$ROOT/Resources"

[ -d "$SRC" ] || { echo "✗ No icon source at $SRC"; exit 1; }
command -v actool >/dev/null || { echo "✗ actool not found — install Xcode"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# actool derives the asset name from the .icon basename, so stage it as AppIcon.
cp -R "$SRC" "$WORK/AppIcon.icon"
mkdir -p "$WORK/out"

echo "▸ Compiling $SRC → AppIcon.icns + Assets.car…"
actool "$WORK/AppIcon.icon" \
  --compile "$WORK/out" \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --errors --warnings >/dev/null

mkdir -p "$OUT"
cp "$WORK/out/AppIcon.icns" "$OUT/AppIcon.icns"
cp "$WORK/out/Assets.car" "$OUT/Assets.car"

echo "✓ Wrote $OUT/AppIcon.icns and $OUT/Assets.car"
