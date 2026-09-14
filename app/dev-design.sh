#!/bin/bash
# Live design loop: rebuild and relaunch the design window whenever a source file changes.
#
#   ./dev-design.sh
#
# This builds `brainio-pen-design`, a separate app from the one people install. It has no pen, no
# notes repo and no menubar item, so it is safe to run while the installed LaunchAgent is running.
#
# The window keeps its position (AppKit frame autosave) and its selected state (UserDefaults),
# so a relaunch reads as a reload.
set -uo pipefail
cd "$(dirname "$0")"

BIN=".build/debug/brainio-pen-design"
PID=""

# Only the layers the design app is built from. An edit to the pen session does not concern it.
stamp() {
  find Sources/BrainioPenCore Sources/BrainioPenUI Sources/BrainioPenDesign Sources/BrainioPenDesignApp \
    -name '*.swift' -exec stat -f '%m %N' {} + | sort | cksum
}

relaunch() {
  OUT="$(swift build --product brainio-pen-design 2>&1)"
  if [[ $? -ne 0 ]]; then
    echo "✗ $(date +%H:%M:%S) build failed — the open window is left alone"
    grep -E 'error:' <<<"$OUT" | head -8
    return
  fi
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null
  "$BIN" &
  PID=$!
  echo "✓ $(date +%H:%M:%S) reloaded"
}

trap '[[ -n "$PID" ]] && kill "$PID" 2>/dev/null; exit 0' INT TERM

LAST="$(stamp)"
relaunch
while true; do
  sleep 0.6
  NOW="$(stamp)"
  if [[ "$NOW" != "$LAST" ]]; then LAST="$NOW"; relaunch; fi
done
