#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typemore"
BUNDLE_ID="com.typemore.local"
VERSION="${VERSION:-${GITHUB_REF_NAME:-0.1.6}}"
VERSION="${VERSION#v}"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ZIP_PATH="$DIST_DIR/$APP_NAME-local.zip"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_TEMP="$DIST_DIR/$APP_NAME-local-rw.dmg"
DMG_PATH="$DIST_DIR/$APP_NAME-local.dmg"
ICON_PNG="$DIST_DIR/$APP_NAME-icon.png"
ICONSET_DIR="$DIST_DIR/$APP_NAME.iconset"
ICON_ICNS="$RESOURCES_DIR/$APP_NAME.icns"

cd "$ROOT_DIR"

UNIVERSAL="${UNIVERSAL:-0}"

if [[ "$UNIVERSAL" == "1" ]]; then
  echo "Building universal (arm64 + x86_64) release binary..."
  swift build --configuration release --triple arm64-apple-macosx --disable-sandbox
  swift build --configuration release --triple x86_64-apple-macosx --disable-sandbox
  ARM_BIN="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
  X86_BIN="$ROOT_DIR/.build/x86_64-apple-macosx/release/$APP_NAME"
  UNIVERSAL_BIN="$DIST_DIR/$APP_NAME-universal"
  mkdir -p "$DIST_DIR"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$UNIVERSAL_BIN"
  BINARY_PATH="$UNIVERSAL_BIN"
else
  echo "Building release binary..."
  swift build --configuration release --disable-sandbox
  BINARY_PATH="$BUILD_DIR/$APP_NAME"
fi

echo "Creating app bundle..."
rm -rf "$APP_DIR" "$ZIP_PATH" "$DMG_ROOT" "$DMG_TEMP" "$DMG_PATH" "$ICON_PNG" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "Generating app icon..."
python3 "$ROOT_DIR/scripts/render-icon.py" "$ICON_PNG" >/dev/null
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

echo "Applying ad-hoc code signature..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Creating zip archive..."
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Creating dmg installer..."
hdiutil detach "/Volumes/$APP_NAME" >/dev/null 2>&1 || true
hdiutil detach "/Volumes/$APP_NAME 1" >/dev/null 2>&1 || true
hdiutil create \
  -volname "$APP_NAME" \
  -size 32m \
  -fs HFS+ \
  "$DMG_TEMP" >/dev/null

MOUNT_OUTPUT="$(hdiutil attach "$DMG_TEMP" -nobrowse -readwrite)"
MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "Failed to mount temporary dmg." >&2
  exit 1
fi

ditto "$APP_DIR" "$MOUNT_POINT/$APP_NAME.app"
ln -s /Applications "$MOUNT_POINT/Applications"

set +e
osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    set dmgFolder to POSIX file "$MOUNT_POINT" as alias
    open dmgFolder
    set dmgWindow to container window of dmgFolder
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set the bounds of dmgWindow to {180, 120, 760, 470}
    set viewOptions to the icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set position of item "$APP_NAME.app" of dmgFolder to {165, 180}
    set position of item "Applications" of dmgFolder to {405, 180}
    update dmgFolder without registering applications
    delay 1
    close dmgWindow
end tell
APPLESCRIPT
LAYOUT_STATUS=$?
set -e
if [[ "$LAYOUT_STATUS" -ne 0 ]]; then
  echo "Warning: Finder layout automation failed. The dmg is still usable, but the window may use default layout." >&2
fi

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$DMG_TEMP" "$DMG_ROOT"

echo
echo "Done."
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo
echo "For first launch on another Mac:"
echo "1. Open $APP_NAME-local.dmg."
echo "2. Drag $APP_NAME.app to Applications."
echo "3. Right-click $APP_NAME.app and choose Open."
echo "4. Enable Accessibility and Input Monitoring permissions for $APP_NAME in System Settings."
