#!/bin/zsh
# Release build check (unsigned): the version is project.yml MARKETING_VERSION, the build number BUILD (default 1).
# Signing with Developer ID, notarizing and the DMG are a separate step (README, Release).
# Usage: scripts/build.sh
set -e
HERE=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
BUILD=${BUILD:-1}
cd $HERE
python3 tools/check-strings.py
xcodegen generate -q
xcodebuild -project DatabaseClient.xcodeproj -scheme DatabaseClient -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/release CURRENT_PROJECT_VERSION=$BUILD build -quiet
APP="build/release/Build/Products/Release/OpenAsy Database Client.app"
echo "OpenAsy Database Client $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") ($BUILD)"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -o 'com.apple.security[a-z.-]*'
