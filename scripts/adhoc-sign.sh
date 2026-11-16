#!/bin/zsh
# Ad-hoc signature of the local (unsigned) build, with its entitlements. Xcode does not put an app group into a
# signature without a provisioning profile ("requires a provisioning profile"), but macOS does open the team-prefixed
# group for an ad-hoc signed app in the sandbox. So local builds are not signed by Xcode (CODE_SIGNING_ALLOWED=NO) and
# this script signs them as the last build step.
# A Developer ID build: CODE_SIGNING_ALLOWED=YES OA_ADHOC_SIGN=NO with the certificate and profile (README, Release).
set -e
[[ "$OA_ADHOC_SIGN" == "YES" ]] || exit 0

# From the test target: the host app is signed again with the exceptions Xcode adds to its own signature when testing
# (reaching testmanagerd, reading the test bundle). Only in test builds; a released app has none of them.
if [[ "$PRODUCT_TYPE" == "com.apple.product-type.bundle.unit-test" ]]; then
  HOST="${TEST_HOST%/Contents/MacOS/*}"
  ENT="$DERIVED_FILE_DIR/host.entitlements"
  [[ -f "$BUILT_PRODUCTS_DIR/.adhoc.entitlements" && -d "$HOST" ]] || exit 0
  cp "$BUILT_PRODUCTS_DIR/.adhoc.entitlements" "$ENT"
  P=/usr/libexec/PlistBuddy
  $P -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only array" -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only:0 string /" \
     -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name array" \
     -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string com.apple.testmanagerd" \
     -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string com.apple.dt.testmanagerd.runner" \
     -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:2 string com.apple.coresymbolicationd" "$ENT" >/dev/null
  codesign -f -s - "$HOST/Contents/PlugIns/$WRAPPER_NAME"   # Xcode signs it again right after
  codesign -f -s - --timestamp=none --generate-entitlement-der --entitlements "$ENT" "$HOST"
  exit 0
fi

[[ "$CODE_SIGNING_ALLOWED" == "NO" ]] || exit 0
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
ENT="$DERIVED_FILE_DIR/adhoc.entitlements"
sed "s/\$(OA_DB_GROUP)/$OA_DB_GROUP/g" "$SRCROOT/$OA_ADHOC_ENTITLEMENTS" > "$ENT"
# Debug: like Xcode's own ad-hoc signature, no hardened runtime and get-task-allow (an ad-hoc test bundle only loads
# this way: a hardened process refuses a library without a team id). Release: hardened.
RUNTIME=(-o runtime)
if [[ "$CONFIGURATION" == "Debug" ]]; then
  RUNTIME=()
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$ENT" >/dev/null
fi
# Inner code first: embedded frameworks and libraries
for f in "$APP"/Contents/Frameworks/*.(framework|dylib)(N) "$APP"/Contents/MacOS/*.dylib(N); do
  codesign -f -s - $RUNTIME "$f"
done
# The test bundle is built after the app, copied into it and signed by its own target; one left from an earlier test
# run is signed here too, or removed if incomplete (otherwise the app's signature cannot be made)
for f in "$APP"/Contents/PlugIns/*.xctest(N); do
  [[ -f "$f/Contents/Info.plist" ]] && codesign -f -s - "$f" || rm -rf "$f"
done
codesign -f -s - $RUNTIME --timestamp=none --generate-entitlement-der --entitlements "$ENT" "$APP"
cp "$ENT" "$BUILT_PRODUCTS_DIR/.adhoc.entitlements"   # the test target signs the host again with this
