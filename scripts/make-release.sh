#!/usr/bin/env bash
# Build a signed release, zip it, write version.json, and (optionally) upload
# both to the update host so the in-app updater can find them.
#
#   bash scripts/make-release.sh            # build + zip + version.json locally
#   bash scripts/make-release.sh --upload   # also scp to www.tokencv.com
#
# The update host serves https://www.tokencv.com/fscapture/{version.json,*.zip}.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=0
[ "${1:-}" = "--upload" ] && UPLOAD=1

# 1. Build the signed .app.
bash scripts/make-app.sh >/dev/null
APP="build/FSCapture.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Version: $VERSION"

# 2. Zip it (ditto keeps the code signature intact).
REL_DIR="release"
mkdir -p "$REL_DIR"
ZIP="$REL_DIR/FSCapture-$VERSION.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Zipped: $ZIP ($(du -h "$ZIP" | cut -f1))"

# 3. version.json (edit NOTES for release notes before shipping).
NOTES="${RELEASE_NOTES:-Bug fixes and improvements.}"
cat > "$REL_DIR/version.json" <<JSON
{
  "version": "$VERSION",
  "url": "https://www.tokencv.com/fscapture/FSCapture-$VERSION.zip",
  "notes": "$NOTES",
  "minSystemVersion": "14.0"
}
JSON
echo "Wrote $REL_DIR/version.json"

# 4. Upload.
if [ "$UPLOAD" = "1" ]; then
  REMOTE="www:/var/www/html/fscapture"
  ssh www "mkdir -p /var/www/html/fscapture"
  scp "$ZIP" "$REL_DIR/version.json" "$REMOTE/"
  echo "Uploaded to https://www.tokencv.com/fscapture/"
fi
