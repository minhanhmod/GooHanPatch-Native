#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/GOHAN.xcarchive"
IPA="$BUILD_DIR/GooHanPatch-unsigned.ipa"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }

xcodebuild \
  -project "$ROOT/ThreeOneOSFive.xcodeproj" \
  -scheme GOHAN \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  archive

APP="$ARCHIVE/Products/Applications/GOHAN.app"
test -d "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable GOHAN" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$IPA" Payload
  rm -rf Payload
)
echo "$IPA"
