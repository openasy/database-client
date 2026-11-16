#!/bin/zsh
# Signed, notarized DMG of the version in project.yml, in build/dist. Nothing secret is in the repository: the
# certificate is in the keychain, the profile is installed, the notary credentials are a keychain profile.
#
# Once, on the Mac that releases:
#   1. A "Developer ID Application" certificate of team 47QC6LXXDZ in the keychain (Xcode, Settings, Accounts,
#      Manage Certificates).
#   2. A Developer ID provisioning profile for com.openasy.database-client with App Groups and the keychain group
#      47QC6LXXDZ.com.openasy.db, installed (double-click it). Its name goes in PROFILE.
#   3. xcrun notarytool store-credentials openasy --apple-id <Apple ID> --team-id 47QC6LXXDZ
#      (asks for an app-specific password and keeps it in the keychain).
#
# Usage: PROFILE="<profile name>" scripts/release.sh   (BUILD: build number, default 1; NOTARY: keychain profile)
set -e
HERE=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
: ${PROFILE:?PROFILE must name the Developer ID provisioning profile}
BUILD=${BUILD:-1}
NOTARY=${NOTARY:-openasy}
TEAM=47QC6LXXDZ
cd $HERE

security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" || {
  echo "No Developer ID Application certificate of team $TEAM in the keychain." >&2
  exit 1
}
xcrun notarytool history --keychain-profile $NOTARY >/dev/null 2>&1 || {
  echo "No notarytool keychain profile named $NOTARY: run xcrun notarytool store-credentials $NOTARY first." >&2
  exit 1
}

python3 tools/check-strings.py
xcodegen generate -q
rm -rf build/dist build/signed
xcodebuild -project DatabaseClient.xcodeproj -scheme DatabaseClient -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/signed CURRENT_PROJECT_VERSION=$BUILD \
  CODE_SIGNING_ALLOWED=YES OA_ADHOC_SIGN=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=$TEAM OA_PROFILE="$PROFILE" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS=--timestamp build -quiet

APP="build/signed/Build/Products/Release/OpenAsy Database Client.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && { echo "The app can be debugged: not a release build." >&2; exit 1; }

# The DMG: the app and a link to Applications, signed, notarized and stapled.
mkdir -p build/dist/dmg
DMG="build/dist/OpenAsy-Database-Client-$VERSION.dmg"
ditto "$APP" "build/dist/dmg/OpenAsy Database Client.app"
ln -s /Applications build/dist/dmg/Applications
hdiutil create -quiet -volname "OpenAsy Database Client $VERSION" -srcfolder build/dist/dmg -fs HFS+ -format UDZO "$DMG"
rm -rf build/dist/dmg
codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile $NOTARY --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
(cd build/dist && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "$DMG"
