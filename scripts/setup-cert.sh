#!/bin/bash
# One-time setup: generate a self-signed code-signing certificate
# and import it into the login keychain.
#
# After this runs you can `./scripts/run.sh` repeatedly and Keychain
# stops prompting for password access (the binary will be signed with
# a stable identity).
#
# Usage: ./scripts/setup-cert.sh

set -euo pipefail

CERT_NAME="TablePlusPlus Dev"
DAYS=3650
P12_PASS="tablepluspluspass"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✓ Identity '$CERT_NAME' already exists and is valid for code signing."
  echo "  Run ./scripts/run.sh"
  exit 0
fi

if security find-certificate -c "$CERT_NAME" > /dev/null 2>&1; then
  echo "ℹ️  Certificate '$CERT_NAME' exists in Keychain but is NOT trusted for codesign."
  echo "   Will re-import + set trust."
  security delete-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

echo "→ Generating self-signed code-signing cert..."
openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days "$DAYS" -nodes \
  -subj "/CN=$CERT_NAME/O=TablePlusPlus/" \
  -addext "basicConstraints=CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>&1 | sed 's/^/  /'

echo "→ Packing into PKCS12..."
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/tpp.p12" -name "$CERT_NAME" \
  -passout "pass:$P12_PASS" 2>&1 | sed 's/^/  /'

echo "→ Importing identity into login keychain..."
security import "$TMP/tpp.p12" \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$P12_PASS" \
  -T /usr/bin/codesign \
  -T /usr/bin/security 2>&1 | sed 's/^/  /'

# Save cert PEM to project for future trust ref
mkdir -p .codesign
cp "$TMP/cert.pem" .codesign/cert.pem

echo
echo "→ Marking certificate as trusted for code signing"
echo "  (you'll see TWO password prompts — both want your macOS LOGIN password)"
echo "  1) sudo to add to system trust store"
echo "  2) macOS confirming the trust change"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain .codesign/cert.pem 2>&1 | sed 's/^/  /' || {
  echo
  echo "✗ sudo trust step failed. Fallback to per-user trust:"
  security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db .codesign/cert.pem 2>&1 | sed 's/^/  /'
}

# Allow codesign to use the private key without prompting each time.
echo
echo "→ Granting codesign permanent access to the private key"
echo "  (one more password prompt — your macOS login password)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "" ~/Library/Keychains/login.keychain-db 2>&1 | sed 's/^/  /' || true

echo
echo "→ Verifying..."
if security find-identity -p codesigning -v | grep -q "$CERT_NAME"; then
  echo "  ✓ Identity '$CERT_NAME' is valid for code signing."
  echo
  echo "Now run ./scripts/run.sh"
else
  echo "  ✗ Identity NOT showing as valid. Manual fallback:"
  echo "    open Keychain Access → find '$CERT_NAME' → right-click → Get Info"
  echo "    → Trust → 'When using this certificate' → 'Always Trust'"
fi
