#!/usr/bin/env bash
# Install "Brainio Pen.app" into ~/Applications and register a LaunchAgent so it starts at login
# and is restarted if it exits. Run scripts/make-app.sh first.
#
# Bluetooth permission is granted in the middle of this, not after it, and the order is the whole
# point — see "granting Bluetooth" below.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-dist/Brainio Pen.app}"
[ -d "$SRC" ] || { echo "$SRC not found; run scripts/make-app.sh" >&2; exit 1; }

# This script copies a bundle; it does not build one. A bundle older than the code it was built
# from installs an app that does not have the change you are installing it for, and says
# "installed" while doing it — which has happened.
if [ -n "$(find Sources -type f -newer "$SRC/Contents/MacOS/brainio-pen" -print -quit 2>/dev/null)" ]; then
  echo "$SRC is older than Sources; run scripts/make-app.sh first" >&2
  exit 1
fi

DEST="$HOME/Applications/Brainio Pen.app"
LABEL="com.brainio.pen"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/BrainioPen"

UID_="$(id -u)"

# Stop our own agent before touching any bundle it might be executing. KeepAlive is armed, so
# deleting the binary out from under a live agent gets it respawned into an ENOENT.
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true

# Retire the PenBridge-era agent. Two agents would both own the pen and both commit to the notes
# repo, which is worse than neither running.
LEGACY_LABEL="com.apoco.penbridge"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -e "$LEGACY_PLIST" ] || launchctl print "gui/$UID_/$LEGACY_LABEL" >/dev/null 2>&1; then
  echo "retiring $LEGACY_LABEL (the app was called PenBridge)"
  launchctl bootout "gui/$UID_/$LEGACY_LABEL" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  rm -rf "$HOME/Applications/PenBridge.app"
fi
# The bundle was briefly BrainioPen.app, before the name took its space.
if [ -d "$HOME/Applications/BrainioPen.app" ]; then
  echo "removing the earlier BrainioPen.app"
  rm -rf "$HOME/Applications/BrainioPen.app"
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$LOGDIR"
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

echo "installed $DEST"

# ── granting Bluetooth ───────────────────────────────────────────────────────────────────────────
# macOS offers the Bluetooth prompt only to an app launched from the Finder. An app started by
# launchd is never asked: CBCentralManager.authorization stays notDetermined and the agent waits
# forever for a radio that is already switched on.
#
# So the Finder launch has to happen *before* the agent is bootstrapped. `open` on a bundle that is
# already running only activates the running copy — it starts no new process and raises no prompt —
# which means an installer that bootstraps first and prints advice afterwards gives advice that
# cannot work. Nothing of ours is running at this point, by the bootout at the top.
#
# The grant is keyed to the code signature as well as the bundle id, and an ad-hoc signature changes
# with every build, so this is needed again after each make-app.sh.
open "$DEST"
echo
echo "A Bluetooth prompt should now be on screen. Allow it — without it the pen cannot connect."

if [ -t 0 ]; then
  printf 'Press Return once you have allowed it, and the agent will take over: '
  read -r _
  pkill -f "$DEST/Contents/MacOS/brainio-pen" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_" "$PLIST"
  echo "started $LABEL"
else
  echo
  echo "Not started, because this is not a terminal and the prompt needs a person. Once you have"
  echo "allowed it, hand over to the agent with:"
  echo "    pkill -f \"$DEST/Contents/MacOS/brainio-pen\""
  echo "    launchctl bootstrap gui/$UID_ \"$PLIST\""
fi

echo
echo "log: $LOGDIR/brainio-pen.log"
echo "stop: launchctl bootout gui/$UID_/$LABEL"
