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

for heading in 'FFmpeg 7.1.2' 'libvpx 1.15.2' 'libaom 3.12.1' 'GRDB.swift 7.11.1'; do
    if ! grep -Fq "$heading" ACKNOWLEDGEMENTS.md; then
        echo "Acknowledgements are missing $heading" >&2
        exit 1
    fi
done

if ! cmp -s ACKNOWLEDGEMENTS.md App/Reel/Sources/Reel/Resources/ACKNOWLEDGEMENTS.md; then
    echo "Bundled acknowledgements are stale; run make licences" >&2
    exit 1
fi

echo "Dependency licences and acknowledgements are approved"
