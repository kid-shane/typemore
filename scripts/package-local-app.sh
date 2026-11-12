#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Typemore"
BUNDLE_ID="com.typemore.local"
VERSION="${VERSION:-${GITHUB_REF_NAME:-0.1.8}}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/release"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
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
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
STAPLE="${STAPLE:-$NOTARIZE}"

cd "$ROOT_DIR"

UNIVERSAL="${UNIVERSAL:-0}"

if [[ "$NOTARIZE" == "1" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "NOTARIZE=1 requires SIGN_IDENTITY to use a Developer ID certificate." >&2
  exit 1
fi

if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
  echo "NOTARIZE=1 requires NOTARY_PROFILE to reference stored notarytool credentials." >&2
  exit 1
fi

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
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Applying ad-hoc code signature..."
  codesign --force --deep --sign - "$APP_DIR"
else
  echo "Applying Developer ID code signature..."
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Creating zip archive..."
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Creating dmg installer..."
MOUNT_POINT=""
detach_build_image() {
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then
      MOUNT_POINT=""
      return 0
    fi
    sleep 1
  done
  hdiutil detach -force "$MOUNT_POINT" >/dev/null
  MOUNT_POINT=""
}
cleanup_build_image() {
  if [[ -n "$MOUNT_POINT" ]]; then
    detach_build_image || true
  fi
}
trap cleanup_build_image EXIT
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
detach_build_image
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$DMG_TEMP" "$DMG_ROOT"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "Signing dmg installer..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting dmg for notarization..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  if [[ "$STAPLE" == "1" ]]; then
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    echo "Recreating zip archive with stapled app..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  fi
fi

echo
echo "Done."
echo "App: $APP_DIR"
echo "Zip: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo
echo "For first launch on another Mac:"
echo "1. Open $APP_NAME-local.dmg."
echo "2. Drag $APP_NAME.app to Applications."
if [[ "$NOTARIZE" == "1" ]]; then
  echo "3. Double-click $APP_NAME.app to open (notarized)."
else
  echo "3. Right-click $APP_NAME.app and choose Open."
fi
echo "4. Enable Accessibility and Input Monitoring permissions for $APP_NAME in System Settings."
