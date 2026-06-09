#!/usr/bin/env bash
#
# Package a .app into a drag-to-Applications DMG.
#
#   ./scripts/make_dmg.sh <path/to/App.app> <path/to/Output.dmg>
#
# Produces a styled DMG (window layout + Applications drop target) when
# `create-dmg` is installed (brew install create-dmg); otherwise falls back to a
# plain functional DMG via hdiutil.
#
set -euo pipefail

APP_PATH="${1:?Usage: make_dmg.sh <App.app> <Output.dmg>}"
DMG_PATH="${2:?Usage: make_dmg.sh <App.app> <Output.dmg>}"

[[ -d "$APP_PATH" ]] || { echo "✗ Not found: $APP_PATH"; exit 1; }

APP_FILE="$(basename "$APP_PATH")"      # e.g. FrameGrab.app
VOL_NAME="$(basename "$APP_PATH" .app)" # e.g. FrameGrab
rm -f "$DMG_PATH"

# Stage just the app in its own folder (the DMG source). create-dmg adds the
# Applications link itself; the hdiutil fallback adds it manually.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"

if command -v create-dmg >/dev/null; then
  echo "▶︎ Building styled DMG with create-dmg…"
  # create-dmg can exit non-zero if it can't code-sign the DMG; that's fine here.
  create-dmg \
    --volname "$VOL_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 120 \
    --icon "$APP_FILE" 160 190 \
    --app-drop-link 440 190 \
    --hide-extension "$APP_FILE" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGING" || true
  [[ -f "$DMG_PATH" ]] && { echo "✓ Created $DMG_PATH"; exit 0; }
  echo "  create-dmg didn't produce a file — falling back to hdiutil."
fi

echo "▶︎ Building plain DMG with hdiutil…"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "✓ Created $DMG_PATH"
echo "  (Install create-dmg for a styled window: brew install create-dmg)"
