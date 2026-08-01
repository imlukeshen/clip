#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
matches="$(
    cd "$repo_root"
    rg -n '[⌘⇧⌃⌥]' App Packages \
        --glob '**/Sources/**/*.swift' \
        --glob '!Packages/DesignSystem/**' || true
)"

if [[ -n "$matches" ]]; then
    echo "Hardcoded shortcut glyphs found outside DesignSystem:"
    echo "$matches"
    exit 1
fi

echo "No hardcoded shortcut glyphs found"
