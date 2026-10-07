#!/bin/bash
set -euo pipefail
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$OUT" "$DERIVED_FILE_DIR/credentials"
OBJECTS=()
for arch in $ARCHS; do
  object="$DERIVED_FILE_DIR/credentials/$arch"
  xcrun --sdk macosx swiftc -sdk "$SDK" -target "$arch-apple-macos13.0" \
    -O "$SRCROOT/MacCredentials/main.swift" -o "$object"
  OBJECTS+=("$object")
done
xcrun lipo -create "${OBJECTS[@]}" -output "$OUT/VesperCredentials"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  if [[ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" || "$EXPANDED_CODE_SIGN_IDENTITY" == - ]]; then
    echo 'error: Vesper Mac requires a stable Apple Development signing identity for its login Keychain.' >&2
    exit 1
  fi
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime \
    --identifier com.vera.vesper.mac.credentials \
    --entitlements "$SRCROOT/MacCredentials/Helper.entitlements" "$OUT/VesperCredentials"
fi
