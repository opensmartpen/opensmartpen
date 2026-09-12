#!/usr/bin/env bash
# Install BrainioPen.app into ~/Applications and register a LaunchAgent so it starts at login
# and is restarted if it exits. Run scripts/make-app.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-dist/BrainioPen.app}"
[ -d "$SRC" ] || { echo "$SRC not found; run scripts/make-app.sh" >&2; exit 1; }

DEST="$HOME/Applications/BrainioPen.app"
LABEL="com.brainio.pen"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/BrainioPen"

# Retire the PenBridge-era agent first. Two agents would both own the pen and both commit to the
# notes repo, which is worse than neither running.
LEGACY_LABEL="com.apoco.penbridge"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -e "$LEGACY_PLIST" ] || launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then
  echo "retiring $LEGACY_LABEL (the app was called PenBridge)"
  launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  rm -rf "$HOME/Applications/PenBridge.app"
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGDIR"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${DEST}/Contents/MacOS/brainio-pen</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>${LOGDIR}/brainio-pen.log</string>
  <key>StandardOutPath</key><string>${LOGDIR}/brainio-pen.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $DEST and started $LABEL"
echo "log: $LOGDIR/brainio-pen.log"
echo "stop: launchctl bootout gui/$(id -u)/$LABEL"
echo
echo "The bundle id changed, so macOS will ask once more for Bluetooth and notification"
echo "permission. Until you grant Bluetooth, the pen will not connect."
