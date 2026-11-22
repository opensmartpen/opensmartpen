#!/usr/bin/env bash
# Install "Open Smart Pen.app" into ~/Applications and register a LaunchAgent so it starts at login
# and is restarted if it exits. Run scripts/make-app.sh first.
#
# Bluetooth permission is granted in the middle of this, not after it, and the order is the whole
# point — see "granting Bluetooth" below.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="${1:-dist/Open Smart Pen.app}"
[ -d "$SRC" ] || { echo "$SRC not found; run scripts/make-app.sh" >&2; exit 1; }

# This script copies a bundle; it does not build one. A bundle older than the code it was built
# from installs an app that does not have the change you are installing it for, and says
# "installed" while doing it — which has happened.
if [ -n "$(find Sources -type f -newer "$SRC/Contents/MacOS/opensmartpen" -print -quit 2>/dev/null)" ]; then
  echo "$SRC is older than Sources; run scripts/make-app.sh first" >&2
  exit 1
fi

DEST="$HOME/Applications/Open Smart Pen.app"
LABEL="org.opensmartpen.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/OpenSmartPen"

UID_="$(id -u)"

# Stop our own agent before touching any bundle it might be executing. KeepAlive is armed, so
# deleting the binary out from under a live agent gets it respawned into an ENOENT.
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
# A copy that a person opened by hand is not the agent's, and the bootout leaves it. Two copies
# would both take the pen, so it goes too.
pkill -x opensmartpen 2>/dev/null || true

# What each signature says the app is, read before the old bundle goes. macOS keeps a grant for as
# long as that answer stays the same, so this is how the script knows whether a person is needed.
# An ad-hoc answer names the binary's own hash and so never matches; one made with a certificate
# (scripts/make-signing-identity.sh) names the bundle id and the certificate, and does.
# A first install has no old bundle to read, and that is an empty answer, not a failure.
requirement() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p' || true; }
WAS="$(requirement "$DEST")"
NOW="$(requirement "$SRC")"

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
  <array><string>${DEST}/Contents/MacOS/opensmartpen</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
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
# The grant is keyed to the code signature as well as the bundle id. When the new bundle's
# signature says what the old one's did, the grant made for the old one still stands, there is
# nothing to prompt for, and the agent can simply be started. OPENSMARTPEN_ASK=1 asks anyway, for
# the day the grant has been revoked in System Settings.
if [ -n "$NOW" ] && [ "$WAS" = "$NOW" ] && [ -z "${OPENSMARTPEN_ASK:-}" ]; then
  launchctl bootstrap "gui/$UID_" "$PLIST"
  echo "started $LABEL (same signature as before, so the Bluetooth grant carries over)"
else
  open "$DEST"
  echo
  echo "A Bluetooth prompt should now be on screen. Allow it — without it the pen cannot connect."

  if [ -t 0 ]; then
    printf 'Press Return once you have allowed it, and the agent will take over: '
    read -r _
    pkill -f "$DEST/Contents/MacOS/opensmartpen" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$UID_" "$PLIST"
    echo "started $LABEL"
  else
    echo
    echo "Not started, because this is not a terminal and the prompt needs a person. Once you have"
    echo "allowed it, hand over to the agent with:"
    echo "    pkill -f \"$DEST/Contents/MacOS/opensmartpen\""
    echo "    launchctl bootstrap gui/$UID_ \"$PLIST\""
  fi
fi

echo
echo "log: $LOGDIR/opensmartpen.log"
echo "stop: launchctl bootout gui/$UID_/$LABEL"
