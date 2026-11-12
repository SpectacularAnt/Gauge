#!/bin/bash
# Builds Gauge and installs it to /Applications.  Usage: ./build.sh
#
#   ./build.sh --bundle-only DIR   builds and signs Gauge.app into DIR and
#                                  stops there, leaving the installed copy
#                                  alone. release.sh uses this.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ONLY=""
if [ "${1:-}" = "--bundle-only" ]; then
  BUNDLE_ONLY="${2:?--bundle-only needs a folder}"
fi

DEST="/Applications/Gauge.app"

# The Command Line Tools ship a Swift 6.3 compiler next to a macOS 27 SDK that
# wants 6.4, so those two refuse to work together.  The macOS 26 SDK is the
# newest one this compiler accepts, and it has everything we use.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [ ! -d "$SDK" ]; then
  echo "error: no macOS 26 SDK at $SDK" >&2
  exit 1
fi

# The bundle is assembled and signed outside this folder on purpose.  This
# folder is in iCloud Drive, which attaches its own file attributes to anything
# written here, and codesign refuses to sign a bundle carrying them.  The app
# then installs to /Applications, so that nothing iCloud might move or evict
# ends up being the copy macOS launches.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Gauge.app"

echo "Compiling..."
mkdir -p "$BUNDLE/Contents/MacOS"

# Sources are in subfolders, so collect them rather than globbing one directory.
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -swift-version 5 \
  -O \
  -o "$BUNDLE/Contents/MacOS/Gauge" \
  $(find Sources -name '*.swift' | sort)

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# The icon. Regenerate it with Tools/make-icon.sh when the artwork changes.
if [ -f Resources/AppIcon.icns ]; then
  mkdir -p "$BUNDLE/Contents/Resources"
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "warning: no Resources/AppIcon.icns — run Tools/make-icon.sh" >&2
fi

# An ad-hoc signature is enough for a local build, and is what lets macOS
# remember Gauge as a login item between launches.
codesign --force --sign - --identifier local.gauge "$BUNDLE"

if [ -n "$BUNDLE_ONLY" ]; then
  mkdir -p "$BUNDLE_ONLY"
  rm -rf "$BUNDLE_ONLY/Gauge.app"
  ditto --noextattr --norsrc "$BUNDLE" "$BUNDLE_ONLY/Gauge.app"
  echo "Built $BUNDLE_ONLY/Gauge.app"
  exit 0
fi

# A running copy cannot be replaced in place.
if pgrep -f "Gauge.app/Contents/MacOS/Gauge" > /dev/null; then
  echo "Quitting the running copy..."
  pkill -f "Gauge.app/Contents/MacOS/Gauge" || true
  sleep 1
fi

rm -rf "$DEST"
# ditto --noextattr leaves iCloud's attributes behind rather than copying them.
ditto --noextattr --norsrc "$BUNDLE" "$DEST"

codesign --verify --deep "$DEST" && echo "signature verifies"

# Finder and the Dock cache icons by path, so a rebuilt icon is often ignored
# until the app is re-registered.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" 2>/dev/null || true

echo "Installed $DEST"

open "$DEST"
echo "Gauge relaunched."
