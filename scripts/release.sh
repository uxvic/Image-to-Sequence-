#!/usr/bin/env bash
#
# Build, package, and (optionally) publish a release with a Sparkle appcast.
#
#   SPARKLE_BIN=/path/to/Sparkle/bin ./scripts/release.sh
#
# Prerequisites (see DISTRIBUTION.md):
#   - xcodegen           (brew install xcodegen)
#   - Sparkle tools      (generate_appcast on PATH, or via SPARKLE_BIN)
#   - EdDSA key in Keychain (one-time: run Sparkle's generate_keys)
#   - gh (optional)      to auto-create the GitHub release
#
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root
ROOT="$PWD"

REPO="uxvic/Image-to-Sequence-"
SCHEME="FrameGrab"
APP_NAME="FrameGrab"
PROJECT="FrameGrab.xcodeproj"

OUT="$ROOT/build/release"
ZIP_DIR="$ROOT/build/appcast-src"
APP_PATH="$ROOT/build/dd/Build/Products/Release/$APP_NAME.app"

# --- 0. App icon ------------------------------------------------------------
# Generate the icon PNGs into the asset catalog if they're missing, so every
# release ships with an icon. Drop a Branding/icon-1024.png to use your own art.
if [[ ! -f "Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" ]]; then
  echo "▶︎ Generating app icon…"
  swift scripts/make_icon.swift
fi

# --- 1. Generate the Xcode project ------------------------------------------
command -v xcodegen >/dev/null || { echo "✗ xcodegen not found — brew install xcodegen"; exit 1; }
echo "▶︎ Generating Xcode project…"
xcodegen generate

# --- 2. Build Release --------------------------------------------------------
rm -rf "$ROOT/build"
mkdir -p "$OUT" "$ZIP_DIR"
echo "▶︎ Building $SCHEME (Release)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$ROOT/build/dd" \
  build

[[ -d "$APP_PATH" ]] || { echo "✗ Build produced no app at $APP_PATH"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
TAG="v$VERSION"
echo "▶︎ Version $VERSION ($TAG)"

# --- 3. Sparkle update archive (.zip) ---------------------------------------
echo "▶︎ Zipping update archive…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_DIR/$APP_NAME.zip"

# --- 4. DMG for humans -------------------------------------------------------
"$ROOT/scripts/make_dmg.sh" "$APP_PATH" "$OUT/$APP_NAME.dmg"

# --- 5. Appcast (signs each update with your EdDSA private key) --------------
GEN="$(command -v generate_appcast || true)"
[[ -z "$GEN" && -n "${SPARKLE_BIN:-}" ]] && GEN="$SPARKLE_BIN/generate_appcast"
if [[ -z "$GEN" || ! -x "$GEN" ]]; then
  echo "✗ generate_appcast not found."
  echo "  Download Sparkle's tools from https://github.com/sparkle-project/Sparkle/releases"
  echo "  then re-run:  SPARKLE_BIN=/path/to/Sparkle/bin ./scripts/release.sh"
  exit 1
fi
echo "▶︎ Generating + signing appcast…"
"$GEN" --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$ZIP_DIR"
cp "$ZIP_DIR/appcast.xml" "$OUT/appcast.xml"

echo
echo "✓ Artifacts:"
echo "    $OUT/$APP_NAME.dmg     ← your friend downloads this"
echo "    $ZIP_DIR/$APP_NAME.zip ← Sparkle update archive"
echo "    $OUT/appcast.xml       ← update feed"
echo

# --- 6. Publish to GitHub Releases (optional) --------------------------------
if command -v gh >/dev/null; then
  echo "▶︎ Publishing GitHub release $TAG…"
  if ! gh release create "$TAG" \
        "$OUT/$APP_NAME.dmg" "$ZIP_DIR/$APP_NAME.zip" "$OUT/appcast.xml" \
        --repo "$REPO" --title "$TAG" --notes "Release $VERSION"; then
    echo "  (release exists — updating assets)"
    gh release upload "$TAG" \
      "$OUT/$APP_NAME.dmg" "$ZIP_DIR/$APP_NAME.zip" "$OUT/appcast.xml" \
      --repo "$REPO" --clobber
  fi
  echo "✓ Published $TAG"
else
  echo "ℹ gh not installed — create the release manually on GitHub:"
  echo "    1. New release, tag: $TAG"
  echo "    2. Attach: $APP_NAME.dmg, $APP_NAME.zip, appcast.xml"
fi
