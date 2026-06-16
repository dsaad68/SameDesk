#!/usr/bin/env bash
#
# Assemble a proper macOS `SameDesk.app` bundle from a SwiftPM build, so the app
# has a stable bundle identity (Screen Recording / Accessibility grants survive
# upgrades) and can be shipped via a Homebrew Cask.
#
# Usage:
#   swift build -c release
#   ./scripts/make-app.sh 1.1.0                 # ad-hoc signed
#   SAMEDESK_SIGN_ID="Developer ID Application: …" ./scripts/make-app.sh 1.1.0
#
# Output: dist/SameDesk.app
#
# Env:
#   CONFIG            release | debug      (default: release)
#   SAMEDESK_SIGN_ID  codesign identity    (default: "-", ad-hoc)
#   SAMEDESK_VERSION  version if no $1 arg (default: 0.0.0-dev)

set -euo pipefail

CONFIG="${CONFIG:-release}"
VERSION="${1:-${SAMEDESK_VERSION:-0.0.0-dev}}"
SIGN_ID="${SAMEDESK_SIGN_ID:--}"
BUNDLE_ID="io.github.dsaad68.SameDesk"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
BIN="$BUILD_DIR/SameDesk"
RES_BUNDLE="$BUILD_DIR/SameDesk_SameDesk.bundle"
APP="$ROOT/dist/SameDesk.app"

[ -x "$BIN" ] || { echo "✗ No binary at $BIN — run: swift build -c $CONFIG"; exit 1; }

echo "▸ Assembling SameDesk.app ($VERSION, $CONFIG)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SameDesk"

# Browser client assets live flat in Contents/Resources; ClientAssets resolves
# them there (see ClientAssets.candidateURLs). Prefer the built resource bundle,
# fall back to the source tree.
if [ -d "$RES_BUNDLE" ]; then
  find "$RES_BUNDLE" \( -name 'client.html' -o -name 'client.js' \) -exec cp {} "$APP/Contents/Resources/" \;
else
  cp "$ROOT/Sources/SameDesk/Client/client.html" \
     "$ROOT/Sources/SameDesk/Client/client.js" "$APP/Contents/Resources/"
fi

# App icon. Built from docs/icon.icon (Icon Composer) via scripts/make-icon.sh:
#   AppIcon.icns  composed raster fallback (every macOS, Finder, older systems)
#   Assets.car    compiled catalog → live Liquid Glass icon on macOS 26 (Tahoe)
# CFBundleIconName selects the catalog icon where present; CFBundleIconFile is
# the fallback. Both reference the same "AppIcon".
ICON_KEY=''
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
fi
if [ -f "$ROOT/Resources/Assets.car" ]; then
  cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICON_KEY="${ICON_KEY}
    <key>CFBundleIconName</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SameDesk</string>
    <key>CFBundleDisplayName</key><string>SameDesk</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>SameDesk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Daniel Saad. MIT License.</string>
    ${ICON_KEY}
</dict>
</plist>
PLIST

echo "▸ Code-signing with identity: $SIGN_ID"
# Assets are plain files (no nested code bundles), so a single outer signature
# covers everything — no --deep needed.
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "✓ signature verifies"

echo "▸ Self-test (resources resolve inside the .app)…"
SAMEDESK_SELFTEST=1 "$APP/Contents/MacOS/SameDesk"

echo "✓ Built $APP"
