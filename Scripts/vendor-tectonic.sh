#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly VERSION="0.16.9"
readonly ARCHIVE="tectonic-${VERSION}-aarch64-apple-darwin.tar.gz"
readonly URL="https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40${VERSION}/${ARCHIVE}"
readonly EXPECTED_SHA256="edb67c61aba768289f6da441c9e6f523cfaff4f8b2a5708523ef29c543f8e88e"
readonly DESTINATION="$ROOT_DIR/Packages/TextEngine/Sources/TextEngine/Resources/Tectonic"
readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl --proto '=https' --tlsv1.2 -fsSL "$URL" -o "$WORK_DIR/$ARCHIVE"
actual_sha256="$(shasum -a 256 "$WORK_DIR/$ARCHIVE" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
    echo "Tectonic checksum mismatch: expected $EXPECTED_SHA256, got $actual_sha256" >&2
    exit 1
fi

tar -xzf "$WORK_DIR/$ARCHIVE" -C "$WORK_DIR"
if [[ "$(file -b "$WORK_DIR/tectonic")" != *"Mach-O 64-bit executable arm64"* ]]; then
    echo "The downloaded Tectonic executable is not a macOS arm64 binary" >&2
    exit 1
fi

mkdir -p "$DESTINATION"
install -m 0755 "$WORK_DIR/tectonic" "$DESTINATION/tectonic"
xattr -c "$DESTINATION/tectonic"
"$DESTINATION/tectonic" --version
shasum -a 256 "$DESTINATION/tectonic"
