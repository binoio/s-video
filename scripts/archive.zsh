#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

ASC_KEY_PATH="${ASC_KEY_PATH:-}"
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"

if ! grep -qE '^DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}' Config.xcconfig; then
  echo "Error: Set DEVELOPMENT_TEAM and SVIDEO_BUNDLE_ID in Config.xcconfig before archiving." >&2
  exit 1
fi

xcodegen generate

ARCHIVE_PATH="build/S-Video.xcarchive"
EXPORT_PATH="build/export"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

AUTH_ARGS=()
if [[ -n "$ASC_KEY_PATH" && -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -f "$ASC_KEY_PATH" ]]; then
  AUTH_ARGS=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild \
  -project S-Video.xcodeproj \
  -scheme S-Video \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  "${AUTH_ARGS[@]}" \
  archive

echo "Archive created at $ARCHIVE_PATH"

if [[ "${1:-}" == "--upload" ]]; then
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "Error: App Store Connect API key not found at $ASC_KEY_PATH" >&2
    exit 1
  fi
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    "${AUTH_ARGS[@]}"
  echo "Uploaded to App Store Connect."
fi
