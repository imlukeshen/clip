#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

make generate >/dev/null

direct_settings="$(xcodebuild -project Clip.xcodeproj -scheme Clip -configuration Release -disableAutomaticPackageResolution -showBuildSettings 2>/dev/null)"
store_settings="$(xcodebuild -project Clip.xcodeproj -scheme Clip-AppStore -configuration AppStoreRelease -disableAutomaticPackageResolution -showBuildSettings 2>/dev/null)"

require_setting() {
    local settings="$1"
    local expected="$2"
    if ! grep -Fq "$expected" <<< "$settings"; then
        echo "Missing distribution build setting: $expected" >&2
        exit 1
    fi
}

require_setting "$direct_settings" "ENABLE_HARDENED_RUNTIME = YES"
require_setting "$direct_settings" "ARCHS = arm64"
require_setting "$direct_settings" "CODE_SIGN_ENTITLEMENTS = App/Reel/Config/Reel.entitlements"
require_setting "$direct_settings" "ENABLE_USER_SCRIPT_SANDBOXING = NO"
require_setting "$direct_settings" "DIRECT_BUILD"
require_setting "$store_settings" "ENABLE_HARDENED_RUNTIME = YES"
require_setting "$store_settings" "ARCHS = arm64"
require_setting "$store_settings" "CODE_SIGN_ENTITLEMENTS = App/Reel/Config/Reel-AppStore.entitlements"
require_setting "$store_settings" "ENABLE_USER_SCRIPT_SANDBOXING = NO"
require_setting "$store_settings" "APPSTORE_BUILD"

readonly TECTONIC_ENTITLEMENTS="App/Reel/Config/TectonicHelper.entitlements"
if ! grep -Fq 'Sign bundled Tectonic' project.yml \
    || ! grep -Fq "TECTONIC_ENTITLEMENTS=\"\$SRCROOT/$TECTONIC_ENTITLEMENTS\"" project.yml \
    || ! grep -Fq '"${CONFIGURATION:-}" == AppStore*' project.yml \
    || ! grep -Fq -- '--entitlements "$TECTONIC_ENTITLEMENTS"' project.yml \
    || ! grep -Fq -- "-path '*/TextEngine_TextEngine.bundle/*/Tectonic/tectonic'" project.yml \
    || ! grep -Fq 'Unable to locate the executable bundled Tectonic tool' project.yml \
    || ! grep -Fq 'codesign --verify --strict "$TECTONIC_PATH"' project.yml; then
    echo "Distribution builds must sign the bundled Tectonic executable" >&2
    exit 1
fi

for plist in App/Reel/Config/ExportOptions-Direct.plist App/Reel/Config/ExportOptions-AppStore.plist; do
    plutil -lint "$plist" >/dev/null
done
for entitlements in \
    App/Reel/Config/Reel.entitlements \
    App/Reel/Config/Reel-AppStore.entitlements \
    "$TECTONIC_ENTITLEMENTS"; do
    plutil -lint "$entitlements" >/dev/null
done
plutil -lint App/Reel/Sources/Reel/Resources/PrivacyInfo.xcprivacy >/dev/null

for key in com.apple.security.app-sandbox com.apple.security.inherit; do
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$TECTONIC_ENTITLEMENTS")" != "true" ]]; then
        echo "Tectonic helper entitlement $key must be true" >&2
        exit 1
    fi
done
helper_entitlement_count="$(/usr/libexec/PlistBuddy -c Print "$TECTONIC_ENTITLEMENTS" | grep -c ' = ')"
if [[ "$helper_entitlement_count" -ne 2 ]]; then
    echo "Tectonic helper must contain only app-sandbox and inherit entitlements" >&2
    exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' \
    App/Reel/Config/Reel.entitlements >/dev/null 2>&1; then
    echo "Direct distribution entitlements must not contain get-task-allow" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' \
    App/Reel/Config/Reel-AppStore.entitlements >/dev/null 2>&1; then
    echo "App Store entitlements must not contain get-task-allow" >&2
    exit 1
fi

echo "Both distribution channels are configured"
