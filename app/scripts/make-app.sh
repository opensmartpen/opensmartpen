#!/usr/bin/env bash
# Build Open Smart Pen in release mode and wrap it in a minimal .app bundle.
# A bundle is needed for Bluetooth permission to be granted to Open Smart Pen itself
# (not the terminal) and for macOS notifications to work.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/Open Smart Pen.app"
BUNDLE_ID="org.opensmartpen.app"
VERSION="$(grep -o 'static let version = "[^"]*"' Sources/OpenSmartPen/AppDelegate.swift | cut -d'"' -f2)"

# The build's own exit status decides, not whether a binary is lying around: a failed build with
# yesterday's binary still in .build/release used to package yesterday's app and say "built".
set -o pipefail
swift build -c release --product opensmartpen 2>&1 | grep -E "error|Build complete" || {
  status=$?
  # grep exits 1 when the build printed neither; only a build failure is fatal.
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "build failed" >&2; exit 1; }
  [ "$status" -le 1 ] || exit "$status"
}
BIN=".build/release/opensmartpen"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/opensmartpen"

# The updater. The binary links Sparkle, so every bundle carries the framework, with or without an
# update feed. The build leaves it beside the binary; a bundle keeps it in Frameworks, and the
# binary is told to look there.
FRAMEWORK=".build/release/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo "build failed: $FRAMEWORK missing" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/opensmartpen"
# The icon is the menubar pencil; scripts/make-icon.swift draws it from the same path. Redrawn
# every build, not cached: the whole point of generating it is that it cannot fall behind the
# pencil it is copied from, and a stale .icns on disk would do exactly that.
swift scripts/make-icon.swift >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Assets.car alongside it: Notification Center resolves the icon through
# CFBundleIconName and the compiled catalog, and ignores CFBundleIconFile entirely.
cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"
# The ideas of the repository: the app shows them under "Ideas…".
cp -R ../ideas "$APP/Contents/Resources/ideas"

# The license texts travel with the app. The built app contains NISDK3, which is GPL-3.0, and the
# GPL asks that each copy of a binary carries the license. The GPL text is taken from the SDK
# checkout the build has just used, so it is always the text of the version that was linked.
SDK_LICENSE=".build/checkouts/iOS-SDK3.0/LICENSE"
[ -f "$SDK_LICENSE" ] || { echo "build failed: $SDK_LICENSE missing" >&2; exit 1; }
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../LICENSE "$APP/Contents/Resources/Licenses/LICENSE-Apache-2.0.txt"
cp ../NOTICE "$APP/Contents/Resources/Licenses/NOTICE.txt"
cp "$SDK_LICENSE" "$APP/Contents/Resources/Licenses/NISDK3-GPL-3.0.txt"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"

# Only a release has an update feed: scripts/package.sh gives the address and the public key of
# the feed's signatures. A release checks each day and downloads a new version with no window;
# Updater.swift then installs it at a quiet moment. Without them the app has no updater at all, so a development build does
# not offer to replace itself with the last release.
UPDATE_KEYS=""
if [ -n "${OPENSMARTPEN_FEED_URL:-}" ] && [ -n "${OPENSMARTPEN_FEED_KEY:-}" ]; then
  UPDATE_KEYS="<key>SUFeedURL</key><string>${OPENSMARTPEN_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${OPENSMARTPEN_FEED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>opensmartpen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Open Smart Pen</string>
  <key>CFBundleDisplayName</key><string>Open Smart Pen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Open Smart Pen connects to your smartpen to sync handwritten notes.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Open Smart Pen connects to your smartpen to sync handwritten notes.</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Apoco s.r.o.</string>
  ${UPDATE_KEYS}
</dict>
</plist>
PLIST

# Signed with this Mac's own certificate when scripts/make-signing-identity.sh has made one, so the
# signature says the same thing about every build — "org.opensmartpen.app, signed by this certificate"
# — and the Bluetooth and notification grants carry over from one build to the next.
#
# Without one, ad hoc: enough to make the bundle launchable, and nothing more. That signature is
# the binary's own hash, so every build is a different app to macOS and has to be allowed again.
IDENTITY="${OPENSMARTPEN_SIGN_IDENTITY:-Open Smart Pen Dev}"
RELEASE_FLAGS=()
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  # A Developer ID is the identity of a public release (scripts/package.sh). Apple notarises only
  # code that has the hardened runtime and a timestamp from Apple's server, so both go on here.
  # The certificate of this Mac gets neither: a timestamp needs the network, and a development
  # build must also work without it.
  case "$IDENTITY" in
    "Developer ID Application:"*) RELEASE_FLAGS=(--options runtime --timestamp) ;;
  esac
  SIGNED="signed as \"$IDENTITY\"; grants carry over"
else
  IDENTITY="-"
  SIGNED="ad-hoc signed; Bluetooth must be allowed again. scripts/make-signing-identity.sh ends that"
fi
sign() {
  codesign --force --sign "$IDENTITY" ${RELEASE_FLAGS[@]+"${RELEASE_FLAGS[@]}"} "$@" >/dev/null
}
# From the inside out: a signature covers what is inside it, so the parts of Sparkle are signed
# before the framework, and the framework before the app. This is the order Sparkle's own
# documentation gives; the downloader keeps the entitlements it came with.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier "$BUNDLE_ID" "$APP"
echo "built $APP (v$VERSION), $SIGNED"
echo "run:   open $APP"
echo "logs:  log stream --predicate 'process == \"opensmartpen\"' --level info   (or run the binary directly for stderr)"
