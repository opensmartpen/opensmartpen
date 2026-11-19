#!/usr/bin/env bash
# Refuse the build in release/ unless it is one a stranger's Mac will open: the app in the zip,
# the DMG, and the app in the DMG are signed with our Developer ID, have the hardened runtime,
# carry the notarisation ticket, and are accepted by Gatekeeper.
#
# The release workflow runs this between scripts/package.sh and the upload. A build that fails
# here and is published all the same is an app that macOS tells each person to move to the Bin.
#
# usage: OPENSMARTPEN_TEAM_ID=<team id> scripts/verify-release.sh
#   The team id is the ten characters in brackets at the end of the certificate's name. It is not
#   a secret; it is asked for so that a build signed by another team's certificate is refused.
set -euo pipefail

cd "$(dirname "$0")/.."

team="${OPENSMARTPEN_TEAM_ID:?set OPENSMARTPEN_TEAM_ID to the Developer ID team}"

work="$(mktemp -d)"
mounted=
cleanup() {
  [ -z "$mounted" ] || hdiutil detach -quiet "$mounted" || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "verify-release: $*" >&2
  exit 1
}

# Prints the signature's details.
signed_by_team() {
  local code="$1" details
  codesign --verify --strict "$code" || fail "$code is not validly signed"
  details="$(codesign --display --verbose=2 "$code" 2>&1)"
  grep -qx "Authority=Developer ID Application: .* ($team)" <<<"$details" ||
    fail "$code is not signed with the Developer ID of team $team"
  printf '%s\n' "$details"
}

verify_app() {
  local app="$1" details
  codesign --verify --deep --strict "$app" || fail "$app is not validly signed"
  details="$(signed_by_team "$app")"
  grep -q "^CodeDirectory .*flags=.*(runtime)" <<<"$details" ||
    fail "$app does not have the hardened runtime that notarisation needs"
  xcrun stapler validate "$app" >/dev/null || fail "$app has no stapled notarisation ticket"
  spctl --assess --type execute "$app" 2>/dev/null || fail "Gatekeeper refuses $app"
  # The GPL asks that each copy of the binary carries the license.
  [ -f "$app/Contents/Resources/Licenses/NISDK3-GPL-3.0.txt" ] ||
    fail "$app does not carry the license texts"
  # A release without the feed is an app that never hears of the next release.
  /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$app/Contents/Info.plist" >/dev/null 2>&1 &&
    /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist" >/dev/null 2>&1 ||
    fail "$app has no update feed"
  echo "ok      $app"
}

shopt -s nullglob
zips=(release/*.zip)
dmgs=(release/*.dmg)
[ "${#zips[@]}" -eq 1 ] || fail "expected one zip in release/, found ${#zips[@]}"
[ "${#dmgs[@]}" -eq 1 ] || fail "expected one DMG in release/, found ${#dmgs[@]}"

# The feed must name the zip that is here, at the size it has: an installed app refuses another.
[ -f release/appcast.xml ] || fail "release/appcast.xml is missing"
grep -q "$(basename "${zips[0]}")\"" release/appcast.xml || fail "the feed does not name ${zips[0]}"
grep -q "length=\"$(stat -f %z "${zips[0]}")\"" release/appcast.xml ||
  fail "the feed gives another size than ${zips[0]} has"
grep -q 'sparkle:edSignature="' release/appcast.xml || fail "the feed has no signature"
echo "ok      release/appcast.xml"

# ditto keeps the signature's extended attributes, which unzip drops.
ditto -x -k "${zips[0]}" "$work/zip"
apps=("$work"/zip/*.app)
[ "${#apps[@]}" -eq 1 ] || fail "expected one app in ${zips[0]}"
verify_app "${apps[0]}"

signed_by_team "${dmgs[0]}" >/dev/null
xcrun stapler validate "${dmgs[0]}" >/dev/null ||
  fail "${dmgs[0]} has no stapled notarisation ticket"
spctl --assess --type open --context context:primary-signature "${dmgs[0]}" 2>/dev/null ||
  fail "Gatekeeper refuses ${dmgs[0]}"
echo "ok      ${dmgs[0]}"

mounted="$work/dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mounted" "${dmgs[0]}"
apps=("$mounted"/*.app)
[ "${#apps[@]}" -eq 1 ] || fail "expected one app in ${dmgs[0]}"
verify_app "${apps[0]}"
