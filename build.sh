#!/bin/bash
# Packages the co-op mod into a .vmz archive for the VostokMods loader.
# Usage: ./build.sh [output_name]
# Output: rtv-coop.vmz (or custom name)
#
# Requires: steam_helper binaries pre-built in ../steam_helper/bin/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEAM_HELPER_DIR="${SCRIPT_DIR}/../steam_helper"
OUTPUT_NAME="${1:-rtv-coop}"
OUTPUT_FILE="${SCRIPT_DIR}/${OUTPUT_NAME}.vmz"

# Ensure bin/ directory exists for helper binaries
mkdir -p "${SCRIPT_DIR}/bin"

# Copy steam helper binaries if available
if [ -f "${STEAM_HELPER_DIR}/bin/steam_helper_linux" ]; then
    cp "${STEAM_HELPER_DIR}/bin/steam_helper_linux" "${SCRIPT_DIR}/bin/"
    echo "Included: steam_helper_linux"
fi
if [ -f "${STEAM_HELPER_DIR}/bin/steam_helper.exe" ]; then
    cp "${STEAM_HELPER_DIR}/bin/steam_helper.exe" "${SCRIPT_DIR}/bin/"
    echo "Included: steam_helper.exe"
fi

# Copy Steam SDK libs
for lib in libsteam_api.so libsteam_api64.so steam_api64.dll; do
    if [ -f "${STEAM_HELPER_DIR}/bin/${lib}" ]; then
        cp "${STEAM_HELPER_DIR}/bin/${lib}" "${SCRIPT_DIR}/bin/"
        echo "Included: ${lib}"
    fi
done

# Clean previous build
rm -f "$OUTPUT_FILE"

# Zip mod contents — paths must match res:// structure
cd "$SCRIPT_DIR/.."
zip -r "$OUTPUT_FILE" \
    mod/mod.txt \
    mod/autoload/ \
    mod/network/ \
    mod/patches/ \
    mod/presentation/ \
    mod/ui/ \
    mod/bin/ \
    -x "mod/.git/*" \
    -x "mod/.gitignore" \
    -x "mod/build.sh" \
    -x "mod/*.vmz" \
    -x "mod/**/*.uid"

echo "Built: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | cut -f1))"
