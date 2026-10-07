#!/bin/bash
# Build the independently signed, local Mac Catalyst app. iPhone signing is untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${VESPER_MAC_BUILD_DIR:-$ROOT/build/mac}"
xcodebuild -project "$ROOT/Vesper.xcodeproj" -scheme VesperMac \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED" build
APP="$DERIVED/Build/Products/Debug-maccatalyst/Vesper Mac.app"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: %s\n' "$APP"
if [[ "${1:-}" == "--install" ]]; then
  ditto "$APP" '/Applications/Vesper Mac.app'
  printf 'Installed: /Applications/Vesper Mac.app\n'
fi
