#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="${TMPDIR:-/tmp}/WaxOnWaxOffValidation"
cd "$ROOT"

xcodegen generate
xcodebuild \
  -project WaxOnWaxOff.xcodeproj \
  -scheme WaxOnWaxOff \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -project WaxOnWaxOff.xcodeproj \
  -scheme WaxOnWaxOff \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS='arm64 x86_64' \
  clean build

APP="$DERIVED/Build/Products/Release/WaxOnWaxOff.app"
plutil -lint "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
lipo -info "$APP/Contents/MacOS/WaxOnWaxOff"
test -f "$APP/Contents/Resources/Assets.car"
test -f "$APP/Contents/Resources/AppIcon.icns"

