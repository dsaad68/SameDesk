#!/usr/bin/env bash
#
# Build SameDesk and code-sign it with a STABLE identity, so the Keychain stops
# re-prompting for the access token on every rebuild.
#
# Why: macOS ties a Keychain item's "Always Allow" permission to the app's
# code-signing identity. An unsigned `swift build` binary is identified by its
# hash, which changes every build — so the Keychain re-prompts each time. Sign
# with a consistent identity and "Always Allow" persists across rebuilds.
#
# Usage:
#   SAMEDESK_SIGN_ID="Apple Development: you@example.com" ./scripts/dev-build.sh
#   SAMEDESK_SIGN_ID="SameDesk Dev" ./scripts/dev-build.sh debug
#
# SAMEDESK_SIGN_ID can be:
#   - your Apple Development / Developer ID certificate name, or
#   - a self-signed code-signing certificate you create once in Keychain Access
#     (Certificate Assistant ▸ Create a Certificate ▸ Code Signing). See README.
#
# If SAMEDESK_SIGN_ID is unset it falls back to ad-hoc signing ("-"), which does
# NOT persist across rebuilds — set a real identity to stop the prompts.

set -euo pipefail

CONFIG="${1:-release}"
SIGN_ID="${SAMEDESK_SIGN_ID:--}"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/SameDesk"
[ -x "$BIN" ] || { echo "✗ Binary not found at $BIN"; exit 1; }

echo "▸ Code-signing with identity: $SIGN_ID"
codesign --force --sign "$SIGN_ID" "$BIN"

if [ "$SIGN_ID" = "-" ]; then
  echo "⚠︎ Ad-hoc signed — the Keychain will still re-prompt after each rebuild."
  echo "  Set SAMEDESK_SIGN_ID to a stable identity to make 'Always Allow' stick."
else
  echo "✓ Signed. Click 'Always Allow' once; future builds with this identity won't re-prompt."
fi
echo "▸ Run: $BIN"
