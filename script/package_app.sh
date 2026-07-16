#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CodexImageGenProxy.xcodeproj"
SCHEME="CodexImageGenProxy"
DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
DIST_DIR="$ROOT_DIR/dist/app"
STAGING_DIR="$DIST_DIR/dmg-root"
APP_NAME="GPTSwitch"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/App/Resources/Info.plist")"

/opt/homebrew/bin/xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
rm -rf "$DERIVED_DATA" "$DIST_DIR"
mkdir -p "$DIST_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

cp -R "$DERIVED_DATA/Build/Products/Release/$APP_NAME.app" "$APP_BUNDLE"
/usr/bin/codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/GPTSwitch-v$VERSION.dmg"

(cd "$DIST_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "GPTSwitch-v$VERSION.zip")
(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "GPTSwitch-v$VERSION.dmg" "GPTSwitch-v$VERSION.zip" > SHA256SUMS.txt)

echo "Artifacts:"
ls -lh "$DIST_DIR/GPTSwitch-v$VERSION.dmg" "$DIST_DIR/GPTSwitch-v$VERSION.zip" "$DIST_DIR/SHA256SUMS.txt"
