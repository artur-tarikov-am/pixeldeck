#!/bin/sh
# Builds the app for Apple silicon and Intel and zips it for another Mac.
set -eu

cd "$(dirname "$0")"
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

xcodebuild -quiet -project PixeldeckMac.xcodeproj -scheme PixeldeckMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$build" build

mkdir -p build
rm -f build/Pixeldeck.zip
ditto -c -k --keepParent "$build/Build/Products/Release/Pixeldeck.app" build/Pixeldeck.zip
echo "$(pwd)/build/Pixeldeck.zip"
