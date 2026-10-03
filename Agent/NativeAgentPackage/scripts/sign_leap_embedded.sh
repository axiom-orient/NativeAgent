#!/bin/sh
# Xcode application target post-build phase, after Embed Frameworks.
# Sign the built copy only; never mutate the downloaded XCFramework.
set -eu
[ "${PLATFORM_NAME:-}" = "iphoneos" ] || exit 0
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${FRAMEWORKS_FOLDER_PATH:?Xcode FRAMEWORKS_FOLDER_PATH is required}"
: "${EXPANDED_CODE_SIGN_IDENTITY:?An iOS signing identity is required}"
leap_framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/LeapSDK.framework"
[ -d "$leap_framework" ] || { echo 'LeapSDK.framework is missing from the built app' >&2; exit 1; }
for leap_library in libie_zip.dylib libinference_engine.dylib libinference_engine_llamacpp_backend.dylib; do
  leap_path="$leap_framework/Frameworks/$leap_library"
  [ -f "$leap_path" ] && [ ! -L "$leap_path" ] || { echo "Missing regular LEAP library: $leap_library" >&2; exit 1; }
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$leap_path"
  /usr/bin/codesign --verify --strict "$leap_path"
done
/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$leap_framework"
/usr/bin/codesign --verify --strict "$leap_framework"
