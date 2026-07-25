#!/usr/bin/env bash
#
# Build FrameGrab from the current source and install it into /Applications.
# This is the "update the app on my Mac" command — no Sparkle keys, no GitHub
# release, no Gatekeeper prompt (locally-built apps aren't quarantined).
#
#   ./scripts/install.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="FrameGrab"
DEST="/Applications/$APP_NAME.app"
DD="$ROOT/build/dd"
APP_PATH="$DD/Build/Products/Release/$APP_NAME.app"

# --- App icon (generated once) ----------------------------------------------
if [[ ! -f "Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" ]]; then
  echo "▶︎ Generating app icon…"
  swift scripts/make_icon.swift
fi

# --- Xcode project ----------------------------------------------------------
command -v xcodegen >/dev/null || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
echo "▶︎ Generating Xcode project…"
xcodegen generate

# --- Build ------------------------------------------------------------------
echo "▶︎ Building $APP_NAME (Release)… this can take a minute."
rm -rf "$DD"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DD" \
  build

[[ -d "$APP_PATH" ]] || { echo "✗ Build produced no app at $APP_PATH"; exit 1; }

# --- Replace the installed copy ---------------------------------------------
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "▶︎ Quitting the running $APP_NAME…"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  sleep 1
fi

echo "▶︎ Installing to $DEST…"
if ! rm -rf "$DEST" 2>/dev/null; then
  echo "✗ Couldn't replace $DEST (permission denied)."
  echo "  Retry with:  sudo ./scripts/install.sh"
  exit 1
fi
cp -R "$APP_PATH" "$DEST"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "✓ Installed $APP_NAME $VERSION to /Applications"
echo "▶︎ Launching…"
open "$DEST"
