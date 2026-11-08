#!/bin/zsh
# Builds DiskScout.app (release) with Info.plist, icon and code signature.
#   Scripts/build-app.sh                     # ad-hoc signed, for local use
#   SIGN_ID="Developer ID Application: You (TEAMID)" Scripts/build-app.sh   # for distribution
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-2.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-com.diskscout.app}"
PURCHASE_URL="${PURCHASE_URL:-https://diskscout.app/buy}"       # your Gumroad product page
GUMROAD_PRODUCT_ID="${GUMROAD_PRODUCT_ID:-}"                   # enables in-app Gumroad key activation
OUT="build"
APP="$OUT/DiskScout.app"

echo "▸ Building release binary (v$VERSION, build $BUILD)"
[ -n "$GUMROAD_PRODUCT_ID" ] || echo "  note: GUMROAD_PRODUCT_ID not set — buyers will need DS1 keys until you rebuild with it"
swift build -c release 2>&1 | tail -1
BIN="$(swift build -c release --show-bin-path)/DiskScout"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskScout"

if [ ! -f "$OUT/AppIcon.icns" ]; then
  echo "▸ Rendering app icon"
  swift Scripts/make-icon.swift "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DiskScout</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DiskScout</string>
  <key>CFBundleDisplayName</key><string>DiskScout</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 DiskScout</string>
  <key>DiskScoutPurchaseURL</key><string>$PURCHASE_URL</string>
  <key>DiskScoutGumroadProductID</key><string>$GUMROAD_PRODUCT_ID</string>
  <key>NSAppleEventsUsageDescription</key><string>DiskScout asks Finder to empty the Trash, and to move items that macOS won\u2019t let DiskScout move itself (such as other apps\u2019 containers).</string>
  <key>NSDesktopFolderUsageDescription</key><string>DiskScout measures the size of files on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DiskScout measures the size of files in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DiskScout measures the size of files in Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>DiskScout can scan external drives you choose.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>DiskScout can scan network volumes you choose.</string>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$APP/Contents/PkgInfo"

cat > "$OUT/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
PLIST

SIGN_ID="${SIGN_ID:--}"
echo "▸ Signing with identity: $SIGN_ID"
codesign --force --deep --options runtime --timestamp --entitlements "$OUT/entitlements.plist" --sign "$SIGN_ID" "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify --verbose=2 "$APP" 2>&1 | tail -1
echo "✓ $APP"
echo
echo "Next: Scripts/make-dmg.sh   (then notarize: xcrun notarytool submit build/DiskScout.dmg --keychain-profile <profile> --wait && xcrun stapler staple build/DiskScout.dmg)"
