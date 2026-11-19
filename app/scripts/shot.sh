#!/bin/bash
# Take a picture of this app's own windows, and nothing else on the screen.
#
# The design was being written blind: built, installed, and then judged by somebody else looking at
# it. This closes that loop — every window of one process, each to its own PNG, so the person (or
# the agent) writing the view can look at what they made before calling it done.
#
#   scripts/shot.sh opensmartpen-design /tmp/shots
#
# Only windows belonging to the named process are captured. The screen around them is never in the
# frame, which matters when somebody else's desktop is behind it.
set -euo pipefail

app="${1:-opensmartpen-design}"
out="${2:-/tmp/opensmartpen-shots}"
mkdir -p "$out"

# CoreGraphics knows every window, its owner and its size. `screencapture -l` then takes exactly
# one of them by id, with its shadow and nothing behind it.
ids=$(swift - "$app" <<'SWIFT'
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.dropFirst().first ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                         kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner.localizedCaseInsensitiveContains(wanted),
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          // Menubar extras and other furniture are a few points tall; a window worth looking at
          // is not.
          width > 120, height > 80
    else { continue }
    let name = (window[kCGWindowName as String] as? String ?? "window")
        .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    print("\(id) \(name.isEmpty ? "window" : name)")
}
SWIFT
)

if [ -z "$ids" ]; then
    echo "no windows on screen for '$app' — is it running, and is the window open?" >&2
    exit 1
fi

n=0
while read -r id name; do
    [ -z "$id" ] && continue
    file="$out/$app-$name-$n.png"
    screencapture -x -o -l"$id" "$file"
    # Halved, because these are Retina windows and a 2x PNG is four times the bytes for no more
    # detail than the eye needs to judge a layout.
    sips -Z 1200 "$file" --out "$file" >/dev/null 2>&1 || true
    echo "$file"
    n=$((n + 1))
done <<< "$ids"
