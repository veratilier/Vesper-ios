#!/bin/bash
# Convert the supplied original artwork into Xcode's required 1024px icon format.
# The checked-in originals stay unchanged. Runs on the Mac building the app.
set -euo pipefail
asset_root="${SRCROOT}/Vesper/Resources/Assets.xcassets"
for palette in White Black; do
    /usr/bin/sips -s format png -z 1024 1024 \
        "${asset_root}/${palette}Emblem.imageset/image.jpeg" \
        --out "${asset_root}/AppIcon${palette}.appiconset/icon.png" >/dev/null
done
