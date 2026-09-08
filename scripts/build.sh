#!/bin/bash
# Builds ActivityMonitor.app. Run with: bash scripts/build.sh
#
# Signing: uses the "Activity Monitor Dev" certificate when it exists, else
# ad-hoc. Ad-hoc works, but its identity is the bundle's own hash, so every
# rebuild looks like a different app and macOS drops the Accessibility grant.
# Run scripts/make-signing-cert.sh once to stop that.
#
# Environment:
#   AM_SIGN_IDENTITY  certificate common name, or "-" to force ad-hoc signing
#   AM_APP_DIR        where to put the .app (default: build)
#   AM_UNIVERSAL=1    build arm64 + x86_64 instead of only this machine's arch
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${AM_APP_DIR:-build}"
APP="$OUT_DIR/ActivityMonitor.app"
BUNDLE_ID="com.topherhunt.activitymonitor"
VERSION="$(tr -d '[:space:]' < VERSION)"
CERT="${AM_SIGN_IDENTITY:-Activity Monitor Dev}"

if [ "$CERT" = "-" ]; then
  IDENTITY="-"
else
  # Sign by certificate fingerprint, not by name: running make-signing-cert.sh
  # twice leaves two identities with the same common name and codesign refuses an
  # ambiguous match. Lowest fingerprint wins so the choice is stable across builds
  # -- which is what the Accessibility grant is pinned to.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v n="$CERT" '$2 == n { print $1 }' \
    | awk '{ print $2 }' | sort | head -1)"

  if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "!! no '$CERT' certificate found; signing ad-hoc."
    echo "!! the Accessibility grant will be dropped on every rebuild."
    echo "!! run 'bash scripts/make-signing-cert.sh' once to fix that."
  fi
fi

if [ "${AM_UNIVERSAL:-0}" = "1" ]; then
  # Two passes and a lipo, because `swift build --arch a --arch b` needs Xcode's
  # xcbuild, which the Command Line Tools do not ship.
  echo "==> swift build (arm64 + x86_64)"
  swift build -c release --triple arm64-apple-macosx13.0  --scratch-path .build/arm64
  swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build/x86
  mkdir -p .build/universal
  lipo -create -output .build/universal/ActivityMonitor \
    .build/arm64/arm64-apple-macosx/release/ActivityMonitor \
    .build/x86/x86_64-apple-macosx/release/ActivityMonitor
  BIN=".build/universal/ActivityMonitor"
else
  echo "==> swift build"
  swift build -c release
  BIN=".build/release/ActivityMonitor"
fi

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ActivityMonitor"
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
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
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
