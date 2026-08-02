#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly BUILD_DIR="${REEL_RELEASE_DIR:-$ROOT_DIR/ReleaseBuild}"
readonly DIRECT_ARCHIVE="$BUILD_DIR/Reel-Direct.xcarchive"
readonly STORE_ARCHIVE="$BUILD_DIR/Reel-AppStore.xcarchive"
readonly DIRECT_EXPORT="$BUILD_DIR/direct"
readonly ARTIFACTS="$BUILD_DIR/artifacts"

require_environment() {
    for name in DEVELOPMENT_TEAM NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER RELEASE_VERSION; do
        if [[ -z "${!name:-}" ]]; then
            echo "Missing required environment variable: $name" >&2
            exit 1
        fi
    done
}

require_environment
cd "$ROOT_DIR"
Scripts/check-distribution.sh
Scripts/check-licenses.sh
xcodegen generate

mkdir -p "$BUILD_DIR" "$DIRECT_EXPORT" "$ARTIFACTS"
readonly VERSION="$RELEASE_VERSION"
readonly MARKETING_VERSION="${VERSION#v}"
readonly BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"

xcodebuild archive \
    -project Reel.xcodeproj \
    -scheme Reel \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$DIRECT_ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

xcodebuild -exportArchive \
    -archivePath "$DIRECT_ARCHIVE" \
    -exportPath "$DIRECT_EXPORT" \
    -exportOptionsPlist App/Reel/Config/ExportOptions-Direct.plist \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$NOTARY_KEY" \
    -authenticationKeyID "$NOTARY_KEY_ID" \
    -authenticationKeyIssuerID "$NOTARY_ISSUER"

readonly DIRECT_APP="$DIRECT_EXPORT/Reel.app"
codesign --verify --deep --strict --verbose=2 "$DIRECT_APP"
spctl --assess --type execute --verbose=2 "$DIRECT_APP" || true

readonly DMG="$ARTIFACTS/Reel-$VERSION.dmg"
hdiutil create -volname Reel -srcfolder "$DIRECT_APP" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

xcodebuild archive \
    -project Reel.xcodeproj \
    -scheme Reel-AppStore \
    -configuration AppStoreRelease \
    -destination 'generic/platform=macOS' \
    -archivePath "$STORE_ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

# destination=upload performs the App Store Connect submission.
xcodebuild -exportArchive \
    -archivePath "$STORE_ARCHIVE" \
    -exportPath "$BUILD_DIR/store-upload" \
    -exportOptionsPlist App/Reel/Config/ExportOptions-AppStore.plist \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$NOTARY_KEY" \
    -authenticationKeyID "$NOTARY_KEY_ID" \
    -authenticationKeyIssuerID "$NOTARY_ISSUER"

echo "Notarized direct artefacts are in $ARTIFACTS; the App Store build was uploaded."
