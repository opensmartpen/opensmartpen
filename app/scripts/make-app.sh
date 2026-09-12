#!/usr/bin/env bash
# Build Brainio Pen in release mode and wrap it in a minimal .app bundle.
# A bundle is needed for Bluetooth permission to be granted to Brainio Pen itself
# (not the terminal) and for macOS notifications to work.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/Brainio Pen.app"
BUNDLE_ID="com.brainio.pen"
VERSION="$(grep -o 'static let version = "[^"]*"' Sources/BrainioPen/AppDelegate.swift | cut -d'"' -f2)"

swift build -c release 2>&1 | grep -E "error|Build complete" || true
BIN=".build/release/brainio-pen"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/brainio-pen"
# The icon is the menubar pencil; scripts/make-icon.swift draws it from the same path. Redrawn
# every build, not cached: the whole point of generating it is that it cannot fall behind the
# pencil it is copied from, and a stale .icns on disk would do exactly that.
swift scripts/make-icon.swift >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Assets.car alongside it: Notification Center resolves the icon through
# CFBundleIconName and the compiled catalog, and ignores CFBundleIconFile entirely.
cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>brainio-pen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
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

# Ad-hoc signature: enough to make the bundle launchable, and nothing more. It does NOT preserve
# TCC grants across rebuilds — the signature changes with the binary, so Bluetooth and
# notification permission have to be granted again after every build. See README, "Moving from
# PenBridge".
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
echo "built $APP (v$VERSION)"
echo "run:   open $APP"
echo "logs:  log stream --predicate 'process == \"brainio-pen\"' --level info   (or run the binary directly for stderr)"
