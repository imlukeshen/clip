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

    for required in --disable-gpl --disable-nonfree --enable-shared --disable-static --disable-programs --disable-doc --enable-libwebp; do
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

for bundled_codec in libwebp.7.dylib libwebpmux.3.dylib libsharpyuv.0.dylib; do
    codec_path="$FRAMEWORK_ROOT/macos-arm64/ReelFFmpeg.framework/Versions/A/Frameworks/$bundled_codec"
    if [[ ! -f "$codec_path" ]]; then
        echo "Bundled codec library is missing: $bundled_codec" >&2
        exit 1
    fi
    if ! file "$codec_path" | grep -Fq 'arm64'; then
        echo "Bundled codec must be Apple silicon arm64: $bundled_codec" >&2
        exit 1
    fi
    if ! otool -D "$codec_path" | grep -Fq "@rpath/$bundled_codec"; then
        echo "Bundled codec install name must use @rpath: $bundled_codec" >&2
        exit 1
    fi
done

if [[ "$found_binary" -eq 0 ]]; then
    echo "Vendored FFmpeg binary is missing" >&2
    exit 1
fi

unexpected_processes="$(
    rg --line-number --fixed-strings 'Process(' "$ROOT_DIR/Packages/ConvertKit/Sources" \
        --glob '!**/LibreOfficeBackend.swift' || true
)"
if [[ -n "$unexpected_processes" ]]; then
    echo "$unexpected_processes" >&2
    echo "ConvertKit must never spawn an FFmpeg executable" >&2
    exit 1
fi

if rg --line-number --ignore-case 'ffmpeg.*executable|executable.*ffmpeg' \
    "$ROOT_DIR/Packages/ConvertKit/Sources"; then
    echo "ConvertKit must link FFmpeg in-process rather than spawn it" >&2
    exit 1
fi

echo "FFmpeg license configuration is LGPL-safe"
