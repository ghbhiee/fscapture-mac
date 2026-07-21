#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "Building FSCapture ($CONFIG)..."
swift build -c "$CONFIG"

APP_NAME="FSCapture.app"
APP_DIR="build/$APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN_PATH=".build/$CONFIG/FSCapture"
if [ ! -f "$BIN_PATH" ]; then
  echo "Binary not found at $BIN_PATH"
  exit 1
fi
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/FSCapture"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

# Regenerate the app icon when missing or when the generator changed.
if [ ! -f Resources/AppIcon.icns ] || [ scripts/make-icon.sh -nt Resources/AppIcon.icns ]; then
  bash scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Sign with the stable "FSCapture Dev" identity so TCC grants persist
# across rebuilds; fall back to ad-hoc when the cert is missing.
SIGN_ID="FSCapture Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --identifier com.hongbo.fscapture "$APP_DIR"
  echo "Signed with stable identity: $SIGN_ID"
else
  codesign --force --sign - --identifier com.hongbo.fscapture "$APP_DIR"
  echo "Signed ad-hoc (run scripts/setup-signing.sh once to make TCC grants persist)"
fi

echo "Built $(pwd)/$APP_DIR"
