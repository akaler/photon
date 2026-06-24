#!/usr/bin/env bash
#
# build_release.sh
# Builds a sleek, minimal .app bundle for Photon Overlay and zips it,
# ready to upload to a GitHub Release.
#
#   Usage:  scripts/build_release.sh
#   Output: dist/Photon_v<VERSION>_arm64.zip
#
set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+' VERSION | head -1 | tr -d '[:space:]')"
if [[ -z "$VERSION" ]]; then
  echo "❌ Could not read a valid version from VERSION (expected e.g. 1.0.0)"
  exit 1
fi

APP_NAME="Photon Overlay"
APP_DIR="dist/$APP_NAME.app"
ZIP_PATH="dist/Photon_v${VERSION}_arm64.zip"
ICON_SRC="Assets/AppIcon.icns"

echo "⚙️  Building Photon Overlay v${VERSION}"

# ── 1. Compile the release binary (arm64) ────────────────────────────────────
echo "› swift build -c release --arch arm64"
swift build -c release --arch arm64

BINARY="$(swift build -c release --arch arm64 --show-bin-path)/photon-overlay"
if [[ ! -f "$BINARY" ]]; then
  echo "❌ Expected binary not found at $BINARY"
  exit 1
fi

# ── 2. Recreate the .app bundle from scratch ────────────────────────────────
echo "› Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Binary (kept as 'photon-overlay' internally; matches CFBundleExecutable)
cp "$BINARY" "$APP_DIR/Contents/MacOS/photon-overlay"

# Icon
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "⚠️  No icon at $ICON_SRC — app will use a generic icon."
fi

# ── 3. Info.plist ───────────────────────────────────────────────────────────
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Photon Overlay</string>
    <key>CFBundleDisplayName</key>
    <string>Photon Overlay</string>
    <key>CFBundleIdentifier</key>
    <string>dev.photon.overlay</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleExecutable</key>
    <string>photon-overlay</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Open Source</string>
</dict>
</plist>
PLIST

# A PkgInfo file is conventional but optional; harmless to include.
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# ── 4. Register the app with Launch Services (icon shows immediately) ───────
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR" 2>/dev/null || true

# ── 5. Zip it up ─────────────────────────────────────────────────────────────
echo "› Zipping → $ZIP_PATH"
rm -f "$ZIP_PATH"
# Use ditto for a Mac-friendly zip that preserves resource forks / icon.
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

# ── 6. Done ──────────────────────────────────────────────────────────────────
ZIP_SIZE="$(du -h "$ZIP_PATH" | cut -f1)"
echo
echo "✅ Built release v${VERSION}"
echo "   App:  $APP_DIR"
echo "   Zip:  $ZIP_PATH  (${ZIP_SIZE})"
echo
echo "Next: create a GitHub Release tagged v${VERSION} and attach this zip."
