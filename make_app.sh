#!/usr/bin/env bash
#
# Builds a distributable, double-clickable ImageToSequence.app from the SwiftPM
# release binary. Requires the Swift toolchain that ships with Xcode / the
# Command Line Tools. Run on macOS:
#
#   ./make_app.sh
#
set -euo pipefail

APP_NAME="ImageToSequence"
DISPLAY_NAME="Image to Sequence"
BUNDLE_ID="com.uxvic.imagetosequence"
VERSION="1.0"
MIN_OS="13.0"

echo "▶︎ Building release binary…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "✗ Could not find built binary at: $BIN_PATH"
  exit 1
fi

APP_DIR="$APP_NAME.app"
echo "▶︎ Assembling $APP_DIR…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

echo "▶︎ Ad-hoc code-signing…"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "  (codesign skipped — app will still run)"

echo "✓ Built $APP_DIR"
echo "  Drag it to /Applications, or double-click to run."
echo "  First launch on an unsigned build: right-click → Open to bypass Gatekeeper."
