#!/bin/bash
set -euo pipefail

readonly VERSION="1.7.12"
readonly CHECKSUM="aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"
readonly INSTALL_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}/actionlint-$VERSION"
readonly ARCHIVE="$RUNNER_TEMP/actionlint-$VERSION.tar.gz"
readonly DOWNLOAD_URL="https://github.com/rhysd/actionlint/releases/download/v$VERSION/actionlint_${VERSION}_darwin_arm64.tar.gz"

mkdir -p "$INSTALL_ROOT"
curl --fail --location --silent --show-error "$DOWNLOAD_URL" --output "$ARCHIVE"
printf '%s  %s\n' "$CHECKSUM" "$ARCHIVE" | shasum -a 256 --check
tar -xzf "$ARCHIVE" -C "$INSTALL_ROOT"
"$INSTALL_ROOT/actionlint" -color
