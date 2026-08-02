#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly FRAMEWORK_ROOT="$ROOT_DIR/Vendor/ffmpeg/ReelFFmpeg.xcframework"

if [[ ! -d "$FRAMEWORK_ROOT" ]]; then
    echo "Vendored FFmpeg framework is missing" >&2
    exit 1
fi

found_binary=0
while IFS= read -r codec_binary; do
    found_binary=1
    configuration="$(strings "$codec_binary" | grep -m 1 -- '--disable-gpl' || true)"
    if [[ -z "$configuration" ]]; then
        echo "FFmpeg configuration string is missing from $codec_binary" >&2
        exit 1
    fi

    for required in --disable-gpl --disable-nonfree --enable-shared --disable-static --disable-programs --disable-doc; do
        if [[ "$configuration" != *"$required"* ]]; then
            echo "FFmpeg configuration is missing $required in $codec_binary" >&2
            exit 1
        fi
    done

    for forbidden in --enable-gpl --enable-nonfree libx264 libx265; do
        if [[ "$configuration" == *"$forbidden"* ]]; then
            echo "Forbidden FFmpeg configuration detected in $codec_binary: $forbidden" >&2
            exit 1
        fi
    done
done < <(find "$FRAMEWORK_ROOT" -type f -name 'libavcodec.*.dylib' -print)

if [[ "$found_binary" -eq 0 ]]; then
    echo "Vendored FFmpeg binary is missing" >&2
    exit 1
fi

if grep -R --line-number --fixed-strings 'Process(' "$ROOT_DIR/Packages/ConvertKit/Sources"; then
    echo "ConvertKit must never spawn an FFmpeg executable" >&2
    exit 1
fi

echo "FFmpeg license configuration is LGPL-safe"
