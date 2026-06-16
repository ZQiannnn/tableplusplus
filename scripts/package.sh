#!/bin/bash
# Build a release binary, assemble TablePlusPlus.app, code-sign it, and
# produce a distributable .dmg. Zero external tooling (uses hdiutil).
#
# Usage:
#   ./scripts/package.sh [--arch arm64|x86_64] [--version X.Y.Z]
#                        [--build N] [--identity NAME]
#
# Defaults: host arch, version from VERSION file, build from git commit count,
# signing identity "TablePlusPlus Dev" if present else ad-hoc ("-").

set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
VERSION=""
BUILD=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)     ARCH="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --build)    BUILD="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$VERSION" ]] && VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
[[ -z "$BUILD"   ]] && BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "✗ unsupported arch: $ARCH"; exit 1 ;;
esac

APP_NAME="TablePlusPlus"
BUNDLE_ID="dev.tableplusplus.app"
TRIPLE="${ARCH}-apple-macosx"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "→ swift build -c release --arch $ARCH"
swift build -c release --arch "$ARCH"

BIN=".build/$TRIPLE/release/$APP_NAME"
[[ -f "$BIN" ]] || { echo "✗ binary not found: $BIN"; exit 1; }

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
[[ -f scripts/AppIcon.icns ]] && cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0</string>
</dict>
</plist>
PLIST

if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning -v 2>/dev/null | grep -q "TablePlusPlus Dev"; then
    IDENTITY="TablePlusPlus Dev"
  else
    IDENTITY="-"
  fi
fi
echo "→ codesign (identity: $IDENTITY)"
codesign --force --deep --options runtime \
  --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "  ✓ signature valid"

DMG="$DIST/$APP_NAME-$VERSION-$ARCH.dmg"
echo "→ building $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
