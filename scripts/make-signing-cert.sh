#!/bin/bash
# Creates a self-signed code signing certificate and imports it into your login
# keychain. Run once, yourself:   bash scripts/make-signing-cert.sh
#
# Why: macOS ties the Accessibility grant to the app's code signature. Ad-hoc
# signing produces a new identity on every build, so the grant is dropped and you
# re-approve the app each time. A stable self-signed cert keeps it. No Apple
# developer account and no Xcode required.
#
# This writes to your login keychain, which is why it is not run automatically.
# To undo: delete "Activity Monitor Dev" in Keychain Access.
set -euo pipefail

NAME="Activity Monitor Dev"
PASS="activitymonitor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> generating self-signed code signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Apple's Security framework rejects OpenSSL 3.x's default PKCS#12 MAC, so pin
# the legacy algorithms it can read.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$PASS"

echo "==> importing into login keychain (may prompt for your password)"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$PASS" -T /usr/bin/codesign

echo "==> trusting it for code signing"
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" || {
    echo "  (trust step failed or was cancelled -- signing may still work; check below)"
  }

echo
security find-identity -p codesigning | tail -5
echo
echo "Now build with:"
echo "  export AM_SIGN_IDENTITY=\"$NAME\""
echo "  bash scripts/build.sh"
