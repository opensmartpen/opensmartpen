#!/usr/bin/env bash
# Build Brainio Pen in release mode and wrap it in a minimal .app bundle.
# A bundle is needed for Bluetooth permission to be granted to Brainio Pen itself
# (not the terminal) and for macOS notifications to work.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/BrainioPen.app"
BUNDLE_ID="com.brainio.pen"
VERSION="$(grep -o 'static let version = "[^"]*"' Sources/BrainioPen/AppDelegate.swift | cut -d'"' -f2)"

swift build -c release 2>&1 | grep -E "error|Build complete" || true
BIN=".build/release/brainio-pen"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/brainio-pen"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>brainio-pen</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Brainio Pen</string>
  <key>CFBundleDisplayName</key><string>Brainio Pen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Brainio Pen connects to your Neo smartpen to sync handwritten notes.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Brainio Pen connects to your Neo smartpen to sync handwritten notes.</string>
  <key>NSHumanReadableCopyright</key><string>Apoco</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so TCC (Bluetooth, notifications) remembers the grant across rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
echo "built $APP (v$VERSION)"
echo "run:   open $APP"
echo "logs:  log stream --predicate 'process == \"brainio-pen\"' --level info   (or run the binary directly for stderr)"
