#!/bin/bash
# Build + codesign + launch.
# Run ./scripts/setup-cert.sh once first.
#
# Usage: ./scripts/run.sh [--release]

set -euo pipefail

CERT_NAME="TablePlusPlus Dev"
CONFIG="debug"
SWIFT_FLAGS=""

if [[ "${1:-}" == "--release" ]]; then
  CONFIG="release"
  SWIFT_FLAGS="-c release"
fi

cd "$(dirname "$0")/.."

# Kill any running instance so Keychain doesn't keep cached access.
pkill -f "\.build/.*/TablePlusPlus" 2>/dev/null || true
sleep 0.3

echo "→ swift build $SWIFT_FLAGS"
swift build $SWIFT_FLAGS

ARCH=$(uname -m)
case "$ARCH" in
  arm64)  TRIPLE="arm64-apple-macosx" ;;
  x86_64) TRIPLE="x86_64-apple-macosx" ;;
  *) echo "unknown arch $ARCH"; exit 1 ;;
esac

BIN=".build/$TRIPLE/$CONFIG/TablePlusPlus"

if [[ ! -f "$BIN" ]]; then
  echo "✗ binary not found at $BIN"
  exit 1
fi

if security find-certificate -c "$CERT_NAME" > /dev/null 2>&1; then
  echo "→ codesign with '$CERT_NAME'"
  codesign --sign "$CERT_NAME" --force --options runtime \
    --identifier dev.tableplusplus.app \
    "$BIN" 2>&1 | sed 's/^/  /'
else
  echo "⚠️  cert '$CERT_NAME' not found. Falling back to ad-hoc (Keychain will prompt every build)."
  echo "    Run ./scripts/setup-cert.sh once to fix this."
  codesign --sign - --force --identifier dev.tableplusplus.app "$BIN"
fi

echo "→ launching"
nohup "$BIN" > /tmp/tpp-swift.log 2>&1 &
disown
sleep 1
pgrep -fl "TablePlusPlus$" || echo "(process not detected, check /tmp/tpp-swift.log)"
