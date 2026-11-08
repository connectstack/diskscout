#!/bin/zsh
# Packages build/DiskScout.app into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/DiskScout.app"
[ -d "$APP" ] || { echo "Run Scripts/build-app.sh first"; exit 1; }
STAGE="build/dmg"
rm -rf "$STAGE" build/DiskScout.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DiskScout" -srcfolder "$STAGE" -ov -format UDZO build/DiskScout.dmg | tail -1
rm -rf "$STAGE"
[ -n "${SIGN_ID:-}" ] && codesign --sign "$SIGN_ID" --timestamp build/DiskScout.dmg
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
cp build/DiskScout.dmg "dist/DiskScout-$VERSION.dmg"
(cd dist && shasum -a 256 "DiskScout-$VERSION.dmg" > "DiskScout-$VERSION.dmg.sha256")
echo "✓ dist/DiskScout-$VERSION.dmg  ($(du -h "dist/DiskScout-$VERSION.dmg" | cut -f1))"
echo "  sha256: $(cut -d' ' -f1 "dist/DiskScout-$VERSION.dmg.sha256")"
