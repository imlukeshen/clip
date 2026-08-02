#!/bin/bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly TEMPLATE="$ROOT_DIR/Vendor/licenses/ACKNOWLEDGEMENTS.template.md"
readonly BUNDLED="$ROOT_DIR/App/Reel/Sources/Reel/Resources/ACKNOWLEDGEMENTS.md"

cp "$TEMPLATE" "$ROOT_DIR/ACKNOWLEDGEMENTS.md"
cp "$TEMPLATE" "$BUNDLED"
echo "Regenerated ACKNOWLEDGEMENTS.md and the bundled copy"
