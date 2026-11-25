#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate

DESTINATION=${1:-"platform=iOS Simulator,name=iPad Pro 11-inch (M5)"}

xcodebuild \
  -project S-Video.xcodeproj \
  -scheme S-Video \
  -configuration Debug \
  -destination "$DESTINATION" \
  test
