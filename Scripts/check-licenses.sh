#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

Scripts/check-ffmpeg-license.sh

unexpected="$(rg -o --no-filename 'https://[^\"]+' --glob Package.swift Packages App Vendor \
    | sort -u | grep -v '^https://github.com/groue/GRDB.swift.git$' || true)"
if [[ -n "$unexpected" ]]; then
    echo "Unreviewed remote Swift package dependencies:" >&2
    echo "$unexpected" >&2
    exit 1
fi

for heading in 'FFmpeg 7.1.2' 'libvpx 1.15.2' 'libaom 3.12.1' 'libwebp 1.6.0' 'GRDB.swift 7.11.1' \
    'PDFium 152.0.7961.0'; do
    if ! grep -Fq "$heading" ACKNOWLEDGEMENTS.md; then
        echo "Acknowledgements are missing $heading" >&2
        exit 1
    fi
done

pdfium_binary="Vendor/pdfium/PDFium.xcframework/macos-arm64/libpdfium.dylib"
expected_pdfium_hash="f2431ccc1b88ab3b940e67cfc8889031fa7ae9516e1d57a346f71b1359392c8a"
actual_pdfium_hash="$(shasum -a 256 "$pdfium_binary" | awk '{print $1}')"
if [[ "$actual_pdfium_hash" != "$expected_pdfium_hash" ]]; then
    echo "The pinned PDFium binary checksum does not match" >&2
    exit 1
fi
if ! file "$pdfium_binary" | grep -Fq 'arm64'; then
    echo "The PDFium binary must be Apple silicon arm64" >&2
    exit 1
fi
if ! otool -D "$pdfium_binary" | grep -Fq '@rpath/libpdfium.dylib'; then
    echo "The PDFium install name must use @rpath" >&2
    exit 1
fi

if ! cmp -s ACKNOWLEDGEMENTS.md App/Reel/Sources/Reel/Resources/ACKNOWLEDGEMENTS.md; then
    echo "Bundled acknowledgements are stale; run make licences" >&2
    exit 1
fi

echo "Dependency licences and acknowledgements are approved"
