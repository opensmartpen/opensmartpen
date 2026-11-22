#!/usr/bin/env bash
# Package Open Smart Pen for a public download, into release/:
#
#   OpenSmartPen-<version>.dmg   what a person downloads and opens
#   OpenSmartPen-<version>.zip   the same app, for Homebrew and for the updater
#   appcast.xml                  the update feed: it names this version and the zip
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
#   SPARKLE_PRIVATE_KEY    the key that signs the update, as Sparkle's generate_keys -x writes it
#
# usage: scripts/package.sh [--version <version>]
#   --version   refuse the build unless the source says this version. The release workflow passes
#               the tag, so a tag that the source does not agree with is not released.
set -euo pipefail

cd "$(dirname "$0")/.."

# Where an installed app looks for a newer version: a file of the newest published release. A
# draft or a trial release is not the newest release, so an installed app does not see one.
REPO_URL="https://github.com/opensmartpen/opensmartpen"
FEED_URL="$REPO_URL/releases/latest/download/appcast.xml"
# The public half of SPARKLE_PRIVATE_KEY. It goes into every release, and an installed app takes
# only an update that the private half signed. Not a secret. Empty: a release has no updater.
FEED_KEY="ENkHxtk6jiHzJ/CzNEN/+5VD3rxoucSBtXGNAsoo8JI="

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
update_key="${SPARKLE_PRIVATE_KEY:-}"
unset MAC_CSC_LINK MAC_CSC_KEY_PASSWORD APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER \
  SPARKLE_PRIVATE_KEY
# The tag the files are downloaded from. The release workflow gives it; a trial tag has a suffix.
tag="${OPENSMARTPEN_RELEASE_TAG:-v$version}"

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
if [ -n "$FEED_KEY" ]; then
  export OPENSMARTPEN_FEED_URL="$FEED_URL" OPENSMARTPEN_FEED_KEY="$FEED_KEY"
fi
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

# The feed. The signature is of the zip as it is published, so it is made after the ticket is on
# the app and the zip is final. An installed app refuses a zip that this signature does not fit.
if [ -n "$FEED_KEY" ] && [ -n "$update_key" ]; then
  printf '%s' "$update_key" > "$work/update-key"
  enclosure="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$work/update-key" "$zip")"
  cat > release/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Open Smart Pen</title>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>$REPO_URL/releases/tag/$tag</link>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO_URL/releases/tag/$tag</sparkle:releaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/$tag/$(basename "$zip")" type="application/octet-stream" $enclosure/>
    </item>
  </channel>
</rss>
XML
else
  echo "package: no update feed (FEED_KEY or SPARKLE_PRIVATE_KEY is not set)" >&2
fi

# The disk image: the app, the Applications folder to drag it to, and a window that says so.
scripts/make-dmg.sh "$app" "$dmg"

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
ls -lh release/
