#!/usr/bin/env bash
# Move a PenBridge-era install over to Brainio Pen, in one go:
#
#   scripts/migrate-from-penbridge.sh            # show what would happen
#   scripts/migrate-from-penbridge.sh --apply    # do it
#
# Order matters. The old agent is stopped before anything moves, because it writes to both the
# config directory and the notes repo and would otherwise be moved out from under itself.
#
# Safe to run twice: every step checks whether it has already happened, and nothing is overwritten.
set -euo pipefail

cd "$(dirname "$0")/.."

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

LEGACY_LABEL="com.apoco.penbridge"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_APP="$HOME/Applications/PenBridge.app"
# Config.configBase honours XDG_CONFIG_HOME, so this has to as well — otherwise the config is
# moved somewhere the app never looks and it quietly starts again from defaults.
CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
LEGACY_CONFIG="$CONFIG_BASE/penbridge"
LEGACY_LOGS="$HOME/Library/Logs/PenBridge"
LEGACY_NOTES="$HOME/PenBridge/notes"

CONFIG="$CONFIG_BASE/brainio-pen"
LOGS="$HOME/Library/Logs/BrainioPen"
NOTES="$HOME/BrainioPen/notes"

say() { if [ "$APPLY" = 1 ]; then echo "  $*"; else echo "  would $*"; fi; }
run() { if [ "$APPLY" = 1 ]; then "$@"; fi; }

[ "$APPLY" = 1 ] || echo "DRY RUN — nothing is changed. Re-run with --apply to commit."
echo

# ── 1. stop the old agent ────────────────────────────────────────────────────────────────────
echo "LaunchAgent"
if launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then
  say "stop and remove $LEGACY_LABEL"
  run launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
else
  echo "  $LEGACY_LABEL is not running"
fi
if [ -e "$LEGACY_PLIST" ]; then
  say "delete $LEGACY_PLIST"
  run rm -f "$LEGACY_PLIST"
fi
if [ -d "$LEGACY_APP" ]; then
  say "delete $LEGACY_APP"
  run rm -rf "$LEGACY_APP"
fi

# ── 2. config directory (config.json + pen-state.json) ───────────────────────────────────────
echo
echo "Config"
if [ ! -d "$LEGACY_CONFIG" ]; then
  echo "  nothing at $LEGACY_CONFIG"
elif [ -f "$CONFIG/config.json" ]; then
  echo "  $CONFIG/config.json already exists — leaving both alone."
  echo "  CHECK IT: if it is only defaults, the paired pen is still in the older file and the"
  echo "  app will start unpaired. Compare the two, then delete whichever you do not want:"
  echo "      diff $LEGACY_CONFIG/config.json $CONFIG/config.json"
else
  say "move the contents of $LEGACY_CONFIG into $CONFIG"
  run mkdir -p "$CONFIG"
  # Contents, not the directory: a launch that happened before this script leaves an empty
  # directory behind, and moving onto it would fail.
  run /bin/sh -c 'cd "$1" && for f in * .[!.]*; do [ -e "$f" ] || continue; mv "$f" "$2/"; done' _ "$LEGACY_CONFIG" "$CONFIG"
  run rmdir "$LEGACY_CONFIG" 2>/dev/null || true
fi

# ── 3. notes repo ────────────────────────────────────────────────────────────────────────────
echo
echo "Notes"
MOVED_NOTES=0
if [ ! -d "$LEGACY_NOTES" ]; then
  echo "  nothing at $LEGACY_NOTES"
elif [ -e "$NOTES" ]; then
  echo "  $NOTES already exists — refusing to merge two note histories."
  echo "  Move it yourself if that is what you want."
else
  say "move $LEGACY_NOTES → $NOTES"
  run mkdir -p "$(dirname "$NOTES")"
  run mv "$LEGACY_NOTES" "$NOTES"
  MOVED_NOTES=1
  # ~/PenBridge is left only if something else is in it.
  run rmdir "$HOME/PenBridge" 2>/dev/null || true
fi

# repoPath must follow the notes, or the app writes to a path that no longer exists.
if [ "$MOVED_NOTES" = 1 ] || { [ "$APPLY" = 0 ] && [ -d "$LEGACY_NOTES" ] && [ ! -e "$NOTES" ]; }; then
  say "point repoPath at ~/BrainioPen/notes in config.json"
  if [ "$APPLY" = 1 ]; then
    python3 - "$CONFIG/config.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if p.exists():
    c = json.loads(p.read_text())
    if c.get("repoPath") in ("~/PenBridge/notes", None):
        c["repoPath"] = "~/BrainioPen/notes"
        p.write_text(json.dumps(c, indent=2, sort_keys=True))
        print("  repoPath → ~/BrainioPen/notes")
    else:
        print(f"  repoPath left as {c['repoPath']!r} — not the old default, so not ours to change")
PY
  fi
fi

# ── 4. logs ──────────────────────────────────────────────────────────────────────────────────
echo
echo "Logs"
if [ -d "$LEGACY_LOGS" ] && [ ! -d "$LOGS" ]; then
  say "move $LEGACY_LOGS → $LOGS"
  run mv "$LEGACY_LOGS" "$LOGS"
elif [ -d "$LOGS" ]; then
  echo "  $LOGS already exists"
else
  echo "  nothing at $LEGACY_LOGS"
fi

# ── 5. build and install ─────────────────────────────────────────────────────────────────────
echo
echo "Install"
say "build and install \"Brainio Pen.app\", and start com.brainio.pen"
if [ "$APPLY" = 1 ]; then
  scripts/make-app.sh
  scripts/install-launchagent.sh
fi

echo
if [ "$APPLY" = 1 ]; then
  echo "Done. macOS will ask once for Bluetooth and notification permission — the bundle id"
  echo "changed, so the old grants do not carry over. The pen will not connect until you allow"
  echo "Bluetooth for Brainio Pen in System Settings → Privacy & Security."
else
  echo "Re-run with --apply to commit."
fi
