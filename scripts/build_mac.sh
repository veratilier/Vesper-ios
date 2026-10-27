#!/bin/bash
# Build the independently signed, local Mac Catalyst app. iPhone signing is untouched.
set -euo pipefail
# A full Xcode may be installed even when xcode-select still points at CLI tools.
if [[ -z "${DEVELOPER_DIR:-}" && ! -x "$(xcode-select -p)/usr/bin/xcodebuild" ]]; then
  for xcode_app in /Applications/Xcode.app "$HOME/Downloads/Xcode-beta.app" "$HOME/Downloads/Xcode.app"; do
    if [[ -x "$xcode_app/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$xcode_app/Contents/Developer"
      break
    fi
  done
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${VESPER_MAC_BUILD_DIR:-$HOME/Library/Developer/Xcode/DerivedData/VesperMac}"
xcodebuild -project "$ROOT/Vesper.xcodeproj" -scheme VesperMac \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED" build
APP="$DERIVED/Build/Products/Debug-maccatalyst/Vesper Mac.app"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
if [[ "${1:-}" == "--install" ]]; then
  # Remove obsolete bundle resources too; retaining old icons breaks code signing.
  rsync -a --delete "$APP/" '/Applications/Vesper Mac.app/'
  codesign --verify --deep --strict '/Applications/Vesper Mac.app'
  printf 'Installed: /Applications/Vesper Mac.app\n'
fi
