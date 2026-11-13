#!/bin/sh
# Builds the menu bar app, puts it into /Applications and starts it.
set -eu

cd "$(dirname "$0")"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

xcodebuild -quiet -project PixeldeckMac.xcodeproj -scheme PixeldeckMac -configuration Release \
  -derivedDataPath "$build" build

pkill -x Pixeldeck || true
while pgrep -x Pixeldeck >/dev/null; do sleep 0.2; done

rm -rf /Applications/Pixeldeck.app
ditto "$build/Build/Products/Release/Pixeldeck.app" /Applications/Pixeldeck.app
open /Applications/Pixeldeck.app
echo "Pixeldeck is running from /Applications"
