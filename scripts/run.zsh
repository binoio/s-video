#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="io.bino.svideo"
SIM_NAME="${1:-}"

if [[ -n "$SIM_NAME" ]]; then
  SIM_UDID=$(xcrun simctl list devices available | grep "$SIM_NAME" | head -n 1 | grep -oE '[0-9A-F-]{36}')
else
  # Prefer an already-booted iPad simulator; otherwise pick the first available iPad Pro
  SIM_UDID=$(xcrun simctl list devices booted | grep -i "iPad" | head -n 1 | grep -oE '[0-9A-F-]{36}' || true)
  if [[ -z "$SIM_UDID" ]]; then
    SIM_UDID=$(xcrun simctl list devices available | grep -i "iPad Pro" | head -n 1 | grep -oE '[0-9A-F-]{36}')
  fi
fi

if [[ -z "$SIM_UDID" ]]; then
  echo "Error: No iPad Simulator found." >&2
  exit 1
fi

xcodegen generate

xcodebuild \
  -project S-Video.xcodeproj \
  -scheme S-Video \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  clean build

APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData"/S-Video-*/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "S-Video.app" | head -n 1)

xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b
if [[ -d "/Applications/Xcode.app/Contents/Applications/DeviceHub.app" ]]; then
  open -a "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
fi
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_UDID" "$APP_PATH"
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
