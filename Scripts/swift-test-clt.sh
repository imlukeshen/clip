#!/bin/bash
#
# Run swift-testing (@Test) package tests on a machine that only has
# CommandLineTools (no full Xcode). Points the compiler, linker, and dynamic
# loader at the CLT-bundled Testing framework and its interop dylib.
#
# Usage: scripts/swift-test-clt.sh <package-path> [extra swift test args...]
#   e.g. scripts/swift-test-clt.sh Packages/CaptureKit --filter CapturePasteboard
#
# This is a local dev convenience only; CI uses the full toolchain via `make`.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <package-path> [extra swift test args...]" >&2
    exit 2
fi

package_path="$1"
shift

fw_dir="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
lib_dir="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

DYLD_FRAMEWORK_PATH="$fw_dir" DYLD_LIBRARY_PATH="$lib_dir" \
    swift test --package-path "$package_path" \
    -Xswiftc -F -Xswiftc "$fw_dir" \
    -Xlinker -F -Xlinker "$fw_dir" \
    -Xlinker -rpath -Xlinker "$fw_dir" \
    -Xlinker -rpath -Xlinker "$lib_dir" \
    "$@"
