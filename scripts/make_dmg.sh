#!/usr/bin/env bash
#
# Package a .app into a drag-to-Applications DMG.
#
#   ./scripts/make_dmg.sh <path/to/App.app> <path/to/Output.dmg>
#
set -euo pipefail

APP_PATH="${1:?Usage: make_dmg.sh <App.app> <Output.dmg>}"
DMG_PATH="${2:?Usage: make_dmg.sh <App.app> <Output.dmg>}"

[[ -d "$APP_PATH" ]] || { echo "✗ Not found: $APP_PATH"; exit 1; }

VOL_NAME="$(basename "$APP_PATH" .app)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "▶︎ Staging $VOL_NAME…"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "▶︎ Building DMG…"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "✓ Created $DMG_PATH"
