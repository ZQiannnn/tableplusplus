#!/bin/bash
# Generate a throwaway self-signed code-signing identity into a dedicated
# CI keychain so package.sh can sign the .app. No Developer ID / notarization.
#
# Usage: ./scripts/ci-cert.sh ["TablePlusPlus Dev"]

set -euo pipefail

CERT_NAME="${1:-TablePlusPlus Dev}"
KEYCHAIN="$HOME/Library/Keychains/tpp-ci.keychain-db"
KPASS="ci-temp-pass"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ generating self-signed codesigning cert '$CERT_NAME'"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 825 -nodes -subj "/CN=$CERT_NAME/O=TablePlusPlus/" \
  -addext "basicConstraints=CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/c.p12" -name "$CERT_NAME" -passout "pass:$KPASS" >/dev/null 2>&1

echo "→ importing into CI keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KPASS" "$KEYCHAIN"
security import "$TMP/c.p12" -k "$KEYCHAIN" -P "$KPASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPASS" "$KEYCHAIN" >/dev/null
# Prepend CI keychain to the user search list so codesign finds the identity.
EXISTING=$(security list-keychains -d user | sed 's/"//g' | xargs)
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

echo "✓ identity ready:"
security find-identity -p codesigning -v "$KEYCHAIN"
