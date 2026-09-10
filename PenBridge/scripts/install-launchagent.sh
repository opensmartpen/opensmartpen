#!/usr/bin/env bash
# Install PenBridge.app into ~/Applications and register a LaunchAgent so it starts at login
# and is restarted if it exits. Run scripts/make-app.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-dist/PenBridge.app}"
[ -d "$SRC" ] || { echo "$SRC not found; run scripts/make-app.sh" >&2; exit 1; }

DEST="$HOME/Applications/PenBridge.app"
LABEL="com.apoco.penbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/PenBridge"

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
  <array><string>${DEST}/Contents/MacOS/penbridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>${LOGDIR}/penbridge.log</string>
  <key>StandardOutPath</key><string>${LOGDIR}/penbridge.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $DEST and started $LABEL"
echo "log: $LOGDIR/penbridge.log"
echo "stop: launchctl bootout gui/$(id -u)/$LABEL"
