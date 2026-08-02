#!/bin/sh
set -eu

package_dir="Packages/AIKit"
forbidden='MediaEngine|LibraryStore'

if rg -n "^[[:space:]]*import[[:space:]]+($forbidden)" "$package_dir/Sources"; then
    echo "AIKit imports a forbidden package" >&2
    exit 1
fi

graph_file=$(mktemp -t reel-aikit-deps)
trap 'rm -f "$graph_file"' EXIT
swift package --package-path "$package_dir" show-dependencies --format json > "$graph_file"
if rg -q "($forbidden)" "$graph_file"; then
    echo "AIKit dependency graph reaches a forbidden package" >&2
    exit 1
fi

echo "AIKit dependency boundary is clean"
