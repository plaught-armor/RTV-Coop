#!/bin/bash
# Packages the co-op mod into a .vmz archive for the VostokMods loader.
# Usage: ./build.sh [output_name]
# Output: rtv-coop.vmz (or custom name)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_NAME="${1:-rtv-coop}"
OUTPUT_FILE="${SCRIPT_DIR}/${OUTPUT_NAME}.vmz"

# Clean previous build
rm -f "$OUTPUT_FILE"

# Zip mod contents (not the folder itself) — paths must match res:// structure
cd "$SCRIPT_DIR/.."
zip -r "$OUTPUT_FILE" \
    mod/mod.txt \
    mod/autoload/ \
    mod/network/ \
    mod/patches/ \
    mod/presentation/ \
    mod/ui/ \
    -x "mod/.git/*" \
    -x "mod/.gitignore" \
    -x "mod/build.sh" \
    -x "mod/*.vmz" \
    -x "mod/**/*.uid"

echo "Built: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | cut -f1))"
