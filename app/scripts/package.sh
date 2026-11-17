#!/usr/bin/env bash
# Package Open Smart Pen for a public download, into release/:
#
#   OpenSmartPen-<version>.dmg   what a person downloads and opens
#   OpenSmartPen-<version>.zip   the same app, for Homebrew and for an updater
#
# With the Apple credentials in the environment, the app and the DMG are signed with the
# Developer ID, notarised by Apple, and carry the ticket. Without them the build is the same
# files, unsigned: good for a look at the DMG, and Gatekeeper refuses it on another Mac.
# scripts/verify-release.sh says which of the two a build is.
#
# The credentials, under the names the release workflow gives them:
#   MAC_CSC_LINK           the Developer ID Application certificate, a .p12 in base64
#   MAC_CSC_KEY_PASSWORD   the password of that .p12
#   APPLE_API_KEY          an App Store Connect API key, the text of the .p8
#   APPLE_API_KEY_ID       the id of that key
#   APPLE_API_ISSUER       the issuer id of that key
#
# usage: scripts/package.sh [--version <version>]
#   --version   refuse the build unless the source says this version. The release workflow passes
#               the tag, so a tag that the source does not agree with is not released.
set -euo pipefail

cd "$(dirname "$0")/.."

want=
while [ $# -gt 0 ]; do
  case "$1" in
    --version) want="${2:?--version needs a value}"; shift 2 ;;
    *) echo "package: unknown argument $1" >&2; exit 2 ;;
  esac
done

version="$(grep -o 'static let version = "[^"]*"' Sources/OpenSmartPen/AppDelegate.swift | cut -d'"' -f2)"
if [ -n "$want" ] && [ "$want" != "$version" ]; then
  echo "package: asked for $want, and AppDelegate.version says $version" >&2
  exit 1
fi

# Taken out of the environment, so that only codesign and notarytool see them and the Swift build
# before them does not.
link="${MAC_CSC_LINK:-}" password="${MAC_CSC_KEY_PASSWORD:-}"
key="${APPLE_API_KEY:-}" key_id="${APPLE_API_KEY_ID:-}" issuer="${APPLE_API_ISSUER:-}"
unset MAC_CSC_LINK MAC_CSC_KEY_PASSWORD APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER

work="$(mktemp -d)"
keychain=
searched=
cleanup() {
  if [ -n "$keychain" ]; then
    # The search list as it was, then the keychain itself.
    # shellcheck disable=SC2086
    [ -z "$searched" ] || security list-keychains -d user -s $searched >/dev/null 2>&1 || true
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

signed=false
if [ -n "$link" ]; then
  [ -n "$password" ] || { echo "package: MAC_CSC_LINK is set and MAC_CSC_KEY_PASSWORD is not" >&2; exit 1; }
  [ -n "$key" ] && [ -n "$key_id" ] && [ -n "$issuer" ] || {
    echo "package: a signed build is notarised, and APPLE_API_KEY, APPLE_API_KEY_ID or APPLE_API_ISSUER is not set" >&2
    exit 1
  }

  # A keychain of its own, deleted at the end: the certificate is in no keychain a person uses.
  keychain="$work/release.keychain-db"
  keychain_password="$(uuidgen)"
  printf '%s' "$link" | base64 --decode > "$work/certificate.p12"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$work/certificate.p12" -k "$keychain" -P "$password" \
    -T /usr/bin/codesign >/dev/null
  # Without this, codesign stops and asks a person for the keychain password.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" \
    "$keychain" >/dev/null
  # codesign looks for an identity only in the keychains on the search list.
  searched="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$keychain" $searched >/dev/null

  identity="$(security find-identity -v -p codesigning "$keychain" |
    grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  [ -n "$identity" ] || {
    echo "package: MAC_CSC_LINK holds no Developer ID Application certificate" >&2
    exit 1
  }
  printf '%s' "$key" > "$work/api-key.p8"
  export OPENSMARTPEN_SIGN_IDENTITY="$identity"
  signed=true
else
  # Not the certificate of this Mac either: a release that is not from the Developer ID is
  # unsigned, and says so, and is not a development build with a release's name.
  export OPENSMARTPEN_SIGN_IDENTITY="-"
fi

notarise() {
  xcrun notarytool submit "$1" --key "$work/api-key.p8" --key-id "$key_id" --issuer "$issuer" --wait
}

rm -rf release
mkdir -p release
scripts/make-app.sh "$work/app"
app="$work/app/Open Smart Pen.app"
zip="release/OpenSmartPen-$version.zip"
dmg="release/OpenSmartPen-$version.dmg"

if [ "$signed" = true ]; then
  # Apple takes an archive, not a folder. The ticket goes on the app itself, so the app opens on
  # a Mac that is offline, and both files below get an app that already carries it.
  ditto -c -k --keepParent "$app" "$work/submit.zip"
  notarise "$work/submit.zip"
  xcrun stapler staple "$app"
fi

# ditto keeps the signature's extended attributes, which zip drops.
ditto -c -k --keepParent "$app" "$zip"

# The disk image: the app, and the Applications folder to drag it to.
mkdir "$work/dmg"
ditto "$app" "$work/dmg/Open Smart Pen.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname "Open Smart Pen" -srcfolder "$work/dmg" -format UDZO -ov "$dmg"

if [ "$signed" = true ]; then
  # Gatekeeper judges the disk image before the app in it, so the image is signed and notarised
  # too.
  codesign --sign "$OPENSMARTPEN_SIGN_IDENTITY" --timestamp "$dmg"
  notarise "$dmg"
  xcrun stapler staple "$dmg"
  echo "packaged v$version, signed as \"$OPENSMARTPEN_SIGN_IDENTITY\" and notarised:"
else
  echo "packaged v$version, UNSIGNED (no MAC_CSC_LINK); Gatekeeper refuses it on another Mac:"
fi
ls -lh "$dmg" "$zip"
