#!/usr/bin/env bash
# Make a code-signing identity for Open Smart Pen, once per Mac, so that a rebuild keeps its
# Bluetooth grant.
#
# macOS keys a permission grant to what the signature says the app *is*. An ad-hoc signature says
# only "this exact binary", so every build is a stranger and has to be allowed again — by a person,
# from the Finder (see install-launchagent.sh). A signature made with a certificate says "the app
# with this bundle id, signed by this certificate", which is as true of the next build as of this
# one. The certificate does not have to be trusted by anybody; it only has to stay the same.
#
# Self-signed, kept in the login keychain, good for ten years. Nothing leaves this Mac and no Apple
# account is involved. make-app.sh uses it when it is there and signs ad hoc when it is not.
set -euo pipefail

NAME="${OPENSMARTPEN_SIGN_IDENTITY:-Open Smart Pen Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in the login keychain; nothing to do"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

# The system openssl on purpose: it writes a PKCS#12 the keychain can read. A Homebrew OpenSSL 3
# writes one it cannot, and the import fails with a message about the passphrase.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.conf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# A throwaway passphrase, because the keychain refuses a PKCS#12 that has none.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout pass:opensmartpen

# -T lets codesign use the key. macOS still asks once, the first time it does; "Always Allow"
# is the answer that makes it the last time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P opensmartpen -T /usr/bin/codesign >/dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" || {
  echo "the identity was imported but the keychain does not list it for code signing" >&2
  exit 1
}
echo "made \"$NAME\" in the login keychain"
echo "next: scripts/make-app.sh && scripts/install-launchagent.sh"
echo "The first signing asks for the keychain password — choose Always Allow. The first install"
echo "asks for Bluetooth one last time; builds after that keep the grant."
