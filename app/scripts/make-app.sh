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

# The build's own exit status decides, not whether a binary is lying around: a failed build with
# yesterday's binary still in .build/release used to package yesterday's app and say "built".
set -o pipefail
swift build -c release --product brainio-pen 2>&1 | grep -E "error|Build complete" || {
  status=$?
  # grep exits 1 when the build printed neither; only a build failure is fatal.
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "build failed" >&2; exit 1; }
  [ "$status" -le 1 ] || exit "$status"
}
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

# The license texts travel with the app. The built app contains NISDK3, which is GPL-3.0, and the
# GPL asks that each copy of a binary carries the license. The GPL text is taken from the SDK
# checkout the build has just used, so it is always the text of the version that was linked.
SDK_LICENSE=".build/checkouts/iOS-SDK3.0/LICENSE"
[ -f "$SDK_LICENSE" ] || { echo "build failed: $SDK_LICENSE missing" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../LICENSE "$APP/Contents/Resources/Licenses/LICENSE-Apache-2.0.txt"
cp ../NOTICE "$APP/Contents/Resources/Licenses/NOTICE.txt"
cp "$SDK_LICENSE" "$APP/Contents/Resources/Licenses/NISDK3-GPL-3.0.txt"

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

# Signed with this Mac's own certificate when scripts/make-signing-identity.sh has made one, so the
# signature says the same thing about every build — "com.brainio.pen, signed by this certificate"
# — and the Bluetooth and notification grants carry over from one build to the next.
#
# Without one, ad hoc: enough to make the bundle launchable, and nothing more. That signature is
# the binary's own hash, so every build is a different app to macOS and has to be allowed again.
IDENTITY="${BRAINIO_PEN_SIGN_IDENTITY:-Brainio Pen Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" >/dev/null
  SIGNED="signed as \"$IDENTITY\"; grants carry over"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
  SIGNED="ad-hoc signed; Bluetooth must be allowed again. scripts/make-signing-identity.sh ends that"
fi
echo "built $APP (v$VERSION), $SIGNED"
echo "run:   open $APP"
echo "logs:  log stream --predicate 'process == \"brainio-pen\"' --level info   (or run the binary directly for stderr)"
