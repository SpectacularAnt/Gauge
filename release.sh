#!/bin/bash
# Publishes a new version of Gauge to GitHub, where "Check for Updates" in
# Gauge's Settings will find it.  Usage: ./release.sh 1.2
#
# What it does, in order:
#   1. sets the version in Resources/Info.plist
#   2. builds and signs Gauge.app, without touching the installed copy
#   3. zips it as Gauge.zip
#   4. commits the version change, tags it v1.2 and pushes both
#   5. creates a GitHub release v1.2 with Gauge.zip attached
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh VERSION, for example ./release.sh 1.2}"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: version must be numbers and dots, like 1.2" >&2
  exit 1
fi
TAG="v$VERSION"
REPO="SpectacularAnt/Gauge"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: commit or put away your changes first, so the release matches the code" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: $TAG already exists" >&2
  exit 1
fi

# The short version is what people see; the build number only has to grow.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
# Edited in place rather than with PlistBuddy, which rewrites the whole file
# and drops its comments.
perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*|\${1}$VERSION|" Resources/Info.plist
perl -0pi -e "s|(<key>CFBundleVersion</key>\s*<string>)[^<]*|\${1}$BUILD|" Resources/Info.plist
if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)" != "$VERSION" ]; then
  echo "error: could not set the version in Resources/Info.plist" >&2
  git checkout -- Resources/Info.plist
  exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
./build.sh --bundle-only "$OUT"
# --keepParent puts Gauge.app itself at the top of the zip.
ditto -c -k --keepParent "$OUT/Gauge.app" "$OUT/Gauge.zip"

git add Resources/Info.plist
git commit -q -m "Version $VERSION"
git tag "$TAG"
git push -q origin HEAD "$TAG"

gh release create "$TAG" "$OUT/Gauge.zip" --repo "$REPO" --title "Gauge $VERSION" \
  --notes "${NOTES:-Gauge $VERSION}"
echo "Released Gauge $VERSION"
