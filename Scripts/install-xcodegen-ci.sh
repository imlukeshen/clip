#!/bin/bash
set -euo pipefail

readonly VERSION="2.46.0"
readonly CHECKSUM="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
readonly INSTALL_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}/xcodegen-$VERSION"
readonly ARCHIVE="$RUNNER_TEMP/xcodegen-$VERSION.zip"
readonly DOWNLOAD_URL="https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"

curl --fail --location --silent --show-error "$DOWNLOAD_URL" --output "$ARCHIVE"
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE" | shasum -a 256 --check
ditto -x -k "$ARCHIVE" "$INSTALL_ROOT"
echo "$INSTALL_ROOT/xcodegen/bin" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
"$INSTALL_ROOT/xcodegen/bin/xcodegen" --version
