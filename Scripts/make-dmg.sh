#!/bin/bash
# Builds a drag-to-Applications DMG without Apple Developer credentials.
#
# `make release` is the signed and notarized channel and needs a Developer ID,
# an App Store Connect key, and a team. This produces the same installer shape
# for anyone who has none of those: contributors testing a build, and downloads
# from a repository that does not hold signing secrets.
#
# The result is ad-hoc signed, which is enough to launch on Apple silicon but
# carries no Developer ID, so Gatekeeper will refuse it on first open until the
# user opens it from the context menu. Scripts/make-dmg.sh prints that caveat
# rather than leaving it to be discovered.
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly BUILD_DIR="${CLIP_DMG_DIR:-$ROOT_DIR/ReleaseBuild/unsigned}"
readonly STAGE_DIR="$BUILD_DIR/stage"
readonly DERIVED_DIR="$BUILD_DIR/DerivedData"

cd "$ROOT_DIR"

VERSION="${RELEASE_VERSION:-$(awk '/MARKETING_VERSION:/ {print $2; exit}' Project.yml)}"
readonly VERSION
if [[ -z "$VERSION" ]]; then
    echo "Could not determine a version. Set RELEASE_VERSION." >&2
    exit 1
fi

readonly DMG_NAME="Clip-$VERSION.dmg"
readonly DMG="$BUILD_DIR/$DMG_NAME"

echo "==> Generating the Xcode project"
make generate

echo "==> Building Clip $VERSION (Release)"
rm -rf "$STAGE_DIR" "$DMG"
mkdir -p "$STAGE_DIR"
xcodebuild build \
    -project Clip.xcodeproj \
    -scheme Clip \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DIR" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$VERSION" \
    -quiet

readonly APP="$DERIVED_DIR/Build/Products/Release/Clip.app"
if [[ ! -d "$APP" ]]; then
    echo "Build did not produce $APP" >&2
    exit 1
fi

echo "==> Ad-hoc signing"
# An arm64 binary must carry at least an ad-hoc signature to launch at all.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Staging the installer"
cp -R "$APP" "$STAGE_DIR/Clip.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "Clip $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

(cd "$BUILD_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo
echo "Built $DMG"
echo "       $(cd "$BUILD_DIR" && cat "$DMG_NAME.sha256")"
echo
echo "This DMG is ad-hoc signed, not notarized. On another Mac, Gatekeeper"
echo "blocks the first launch: open Clip from the Finder context menu and"
echo "choose Open, or run 'xattr -dr com.apple.quarantine /Applications/Clip.app'."
echo "Use 'make release' with Developer ID credentials for a notarized build."
