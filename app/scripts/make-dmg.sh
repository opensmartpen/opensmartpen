#!/usr/bin/env bash
# Make the disk image a person downloads: the app, the Applications folder, and a window that
# says what to do with them.
#
#   scripts/make-dmg.sh <Open Smart Pen.app> <file.dmg>
#
# The window has the app on the left, an arrow, and Applications on the right, on a picture that
# scripts/make-dmg-background.swift draws. The Finder keeps how a window looks in a hidden file
# of the folder, and the only way to write that file is to ask the Finder to arrange the window.
# So the image is made writable first, arranged, and then made into the small read-only one.
#
# If the Finder cannot be asked (no permission to script it, or no screen), the image is still
# made: the same two things in a plain window. A release must not fail for the sake of a picture.
set -euo pipefail

app="${1:?usage: make-dmg.sh <app> <dmg>}"
dmg="${2:?usage: make-dmg.sh <app> <dmg>}"
here="$(cd "$(dirname "$0")" && pwd)"
name="Open Smart Pen"

work="$(mktemp -d)"
mount=""
cleanup() {
  [ -n "$mount" ] && hdiutil detach "$mount" -quiet -force 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/root/.background"
ditto "$app" "$work/root/$name.app"
ln -s /Applications "$work/root/Applications"
picture=false
if swift "$here/make-dmg-background.swift" "$work/root/.background/background.png" 2>/dev/null; then
  picture=true
else
  rm -rf "$work/root/.background"
fi

# Writable, with room to spare for the file the Finder writes.
hdiutil create -quiet -volname "$name" -srcfolder "$work/root" -fs HFS+ -format UDRW -ov "$work/rw.dmg"

arranged=false
if [ "$picture" = true ]; then
  # Under /Volumes, where the system puts it, and not at a place of our own: the Finder keeps
  # the picture as a link to a file on a disk it knows, and for a disk mounted somewhere else it
  # kept a plain colour and no picture (seen 2026-11-22). The name can get a number at the end
  # when a disk of the same name is there already, so the place is read from the answer.
  mount="$(hdiutil attach "$work/rw.dmg" -noautoopen | grep -o '/Volumes/.*$' | tail -1)"
  if [ -n "$mount" ] && [ -d "$mount" ]; then
    # The places are in points from the top left of the window: the app at 150, Applications at
    # 450, both 215 down. The arrow in the picture is drawn between the same two.
    if osascript >/dev/null 2>"$work/finder.err" <<APPLESCRIPT
tell application "Finder"
  set theDisk to (POSIX file "$mount" as alias)
  -- A window of its own, asked for by name. "open" alone can give a tab of a window that is
  -- open already, and a tab has no size and no toolbar of its own to set, so nothing about the
  -- window would be kept in the image.
  set theWindow to make new Finder window to theDisk
  set current view of theWindow to icon view
  -- Each of these three can be refused, for example when the Finder opens the disk as a tab of
  -- a window that is open already. The window is then less tidy; the icons and the picture,
  -- which are what matter, are set below in each case.
  try
    set toolbar visible of theWindow to false
  on error
    log "toolbar not hidden"
  end try
  try
    set statusbar visible of theWindow to false
  on error
    log "status bar not hidden"
  end try
  try
    set the bounds of theWindow to {200, 140, 800, 568}
  on error
    log "window size not set"
  end try
  set theOptions to the icon view options of theWindow
  set arrangement of theOptions to not arranged
  set icon size of theOptions to 112
  set text size of theOptions to 13
  set background picture of theOptions to (POSIX file "$mount/.background/background.png" as alias)
  set position of item "$name.app" of theDisk to {150, 215}
  set position of item "Applications" of theDisk to {450, 215}
  -- For a person who has the Finder show hidden files: the two hidden folders go far down and to
  -- the right, out of the window, and not on top of the picture.
  try
    set position of item ".background" of theDisk to {900, 900}
  end try
  try
    set position of item ".fseventsd" of theDisk to {1020, 900}
  end try
  update theDisk without registering applications
  delay 1
  try
    close theWindow
  end try
end tell
APPLESCRIPT
    then
      arranged=true
      [ -s "$work/finder.err" ] && echo "make-dmg: the Finder refused: $(tr '\n' ' ' < "$work/finder.err")" >&2
    else
      echo "make-dmg: the Finder said: $(tr '\n' ' ' < "$work/finder.err")" >&2
    fi
    # The Finder writes its hidden file some moments after it is asked, and a disk taken away
    # before that keeps the places of the icons and loses the picture. So wait for the picture
    # to be in the file, and say so if it never comes.
    if [ "$arranged" = true ]; then
      kept=false
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sync
        if grep -q "backgroundImageAlias" "$mount/.DS_Store" 2>/dev/null; then kept=true; break; fi
        sleep 1
      done
      if [ "$kept" = false ]; then
        echo "make-dmg: the Finder did not keep the picture; the window has the icons in place and a plain ground" >&2
      fi
    fi
    sync
    # The Finder writes its hidden file one more time as the disk goes, and that last copy has
    # the places of the icons and no picture (seen 2026-11-22: 10 KB with the picture before, 6 KB
    # without it after). So the good copy is taken now, and put back into the image while the
    # Finder cannot see the disk.
    saved=false
    if [ "$arranged" = true ] && cp "$mount/.DS_Store" "$work/DS_Store" 2>/dev/null; then saved=true; fi
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -quiet -force || true
    mount=""
    if [ "$saved" = true ]; then
      mkdir "$work/quiet"
      if hdiutil attach "$work/rw.dmg" -quiet -noautoopen -nobrowse -mountpoint "$work/quiet"; then
        mount="$work/quiet"
        cp "$work/DS_Store" "$mount/.DS_Store"
        sync
        hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -quiet -force || true
        mount=""
      fi
    fi
  fi
fi

rm -f "$dmg"
hdiutil convert "$work/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$dmg"
if [ "$arranged" = true ]; then
  echo "make-dmg: $dmg, with the arranged window"
else
  echo "make-dmg: $dmg, with a plain window (the Finder could not be asked to arrange it)" >&2
fi
