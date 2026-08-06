#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

Scripts/check-ffmpeg-license.sh
python3 Scripts/check-resolved-packages.py

declared="$(rg -o --no-filename 'https://[^\"]+' --glob Package.swift Packages App Vendor | sort -u)"
unexpected="$(comm -23 <(printf '%s\n' "$declared") <(sort Scripts/allowed-package-urls.txt) || true)"
if [[ -n "$unexpected" ]]; then
    echo "Unreviewed remote Swift package dependencies:" >&2
    echo "$unexpected" >&2
    exit 1
fi

missing="$(comm -13 <(printf '%s\n' "$declared") <(sort Scripts/allowed-package-urls.txt) || true)"
if [[ -n "$missing" ]]; then
    echo "Approved Swift package dependencies no longer declared:" >&2
    echo "$missing" >&2
    exit 1
fi

for heading in 'FFmpeg 7.1.2' 'libvpx 1.15.2' 'libaom 3.12.1' 'libwebp 1.6.0' 'GRDB.swift 7.11.1' \
    'PDFium 152.0.7961.0' 'Tree-sitter syntax engine' 'Swift Markdown 0.8.0' 'KaTeX 0.17.0' \
    'Tectonic 0.16.9'; do
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

tectonic_binary="Packages/TextEngine/Sources/TextEngine/Resources/Tectonic/tectonic"
expected_tectonic_hash="e62304878074c889e7f96d169698632c4fe695b525fb54a3473d7b2128f54512"
actual_tectonic_hash="$(shasum -a 256 "$tectonic_binary" | awk '{print $1}')"
if [[ "$actual_tectonic_hash" != "$expected_tectonic_hash" ]]; then
    echo "The pinned Tectonic binary checksum does not match" >&2
    exit 1
fi
if [[ ! -x "$tectonic_binary" ]] || ! file "$tectonic_binary" | grep -Fq 'arm64'; then
    echo "The Tectonic binary must be an executable Apple silicon arm64 build" >&2
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
