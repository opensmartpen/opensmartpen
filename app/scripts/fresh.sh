#!/usr/bin/env bash
# Run the app as a new person sees it, apart from the real app of this Mac.
#
# The real app keeps its config in ~/.config/opensmartpen and its notes in ~/OpenSmartPen. This
# script starts a copy of the app on an empty config and an empty notes folder, both under
# ~/OpenSmartPen-fresh, so the copy shows the welcome window and the first panel. Nothing of the
# real app is read or changed.
#
# usage: scripts/fresh.sh [app]
#   app   the bundle to run. The default is the developer build, dist/Open Smart Pen.app.
#         For a draft release, give the app from its disk image or from /Applications.
#
# The real app is stopped for the time of the run, because two copies would both take the pen.
# It starts again when the fresh copy quits. A pen that the real app knows is not known here:
# add it with "Add Pen", and it is still paired in the real app after the run.
#
# What is not fresh: the answer macOS has for Bluetooth, and the app's own preferences. To be
# asked about Bluetooth again:  tccutil reset BluetoothAlways org.opensmartpen.app
# The real app then needs the answer again too.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${1:-dist/Open Smart Pen.app}"
[ -d "$APP" ] || { echo "$APP not found; run scripts/make-app.sh, or give the path of an app" >&2; exit 1; }

LABEL="org.opensmartpen.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_="$(id -u)"
FRESH="$HOME/OpenSmartPen-fresh"

# The real app, in each way it can run: under the LaunchAgent, or opened by hand.
WAS_AGENT=""
if launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
  WAS_AGENT=1
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
fi
pkill -x opensmartpen 2>/dev/null || true
sleep 1

# Back to the real app, also when this script is stopped with Ctrl-C.
restore() {
  pkill -x opensmartpen 2>/dev/null || true
  sleep 1
  if [ -n "$WAS_AGENT" ] && [ -f "$PLIST" ]; then
    launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null || true
    echo "the real app runs again"
  fi
}
trap restore EXIT

# Each run starts from nothing. The config has one line: where the notes go. Without it the
# fresh copy would write into the real notes folder.
rm -rf "$FRESH"
mkdir -p "$FRESH/config/opensmartpen" "$FRESH/notes"
printf '{ "dataPath": "%s/notes" }\n' "$FRESH" > "$FRESH/config/opensmartpen/config.json"

echo "fresh run of $APP"
echo "config and notes: $FRESH"
echo "Quit the app from its panel to end the run."

# `open` starts the app as the Finder does, so macOS can ask about Bluetooth. -n makes a new
# copy, -W waits until it quits.
open -n -W --env "XDG_CONFIG_HOME=$FRESH/config" "$APP"
