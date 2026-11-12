#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/MakeIcon.swift.
# Only needed when the artwork changes — build.sh just copies the result.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "Compiling the icon generator..."
swiftc -sdk "$SDK" -target arm64-apple-macosx14.0 -O \
  -o "$STAGE/makeicon" Tools/MakeIcon.swift

echo "Drawing each size..."
"$STAGE/makeicon" "$STAGE/AppIcon.iconset"

mkdir -p Resources
iconutil -c icns "$STAGE/AppIcon.iconset" -o Resources/AppIcon.icns

# A copy to look at, since .icns files do not preview well on their own.
cp "$STAGE/AppIcon.iconset/icon_512x512.png" Resources/AppIcon-preview.png

echo "Wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
