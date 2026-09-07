#!/bin/bash
# Builds ActivityMonitor.app. Run with: bash scripts/build.sh
#
# Signing: ad-hoc by default, which works but makes macOS forget the
# Accessibility grant on every rebuild. Run scripts/make-signing-cert.sh once,
# then export AM_SIGN_IDENTITY="Activity Monitor Dev" to keep the grant.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ActivityMonitor.app"
BUNDLE_ID="com.topherhunt.activitymonitor"
IDENTITY="${AM_SIGN_IDENTITY:--}"

echo "==> swift build"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ActivityMonitor "$APP/Contents/MacOS/ActivityMonitor"
cp Sources/ActivityMonitor/Resources/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Activity Monitor</string>
  <key>CFBundleDisplayName</key>       <string>Activity Monitor</string>
  <key>CFBundleExecutable</key>        <string>ActivityMonitor</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Activity Monitor reads the active tab's URL so browser time can be categorized by site.</string>
</dict>
</plist>
PLIST

echo "==> signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E 'Identifier|Signature|Authority' || true

echo
echo "Built $APP"
echo "Run it with:  open $APP"
