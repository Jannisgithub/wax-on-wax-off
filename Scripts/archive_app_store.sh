#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR

XCODE_VERSION="$(xcodebuild -version | head -n 1)"
if [[ "$XCODE_VERSION" == *beta* || "$DEVELOPER_DIR" == *Xcode-beta.app* ]]; then
  print -u2 "Use an App Store Connect-supported production Xcode, not Xcode beta."
  exit 2
fi

xcodegen generate
xcodebuild \
  -project WaxOnWaxOff.xcodeproj \
  -scheme WaxOnWaxOff \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ROOT/build/WaxOnWaxOff.xcarchive" \
  -allowProvisioningUpdates \
  clean archive

xcodebuild \
  -exportArchive \
  -archivePath "$ROOT/build/WaxOnWaxOff.xcarchive" \
  -exportOptionsPlist "$ROOT/Store/ExportOptions.plist" \
  -exportPath "$ROOT/build/AppStoreUpload" \
  -allowProvisioningUpdates

