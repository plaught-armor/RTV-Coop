#!/bin/bash
# Packages the co-op mod into a .vmz archive for the Metro Mod Loader.
# Usage: ./build.sh [output_name]
# Output: rtv-coop.vmz (or custom name)
#
# Archive structure:
#   mod.txt              <- root (mod loader reads this)
#   mod/autoload/...     <- res://mod/ prefix (matches preload paths)
#   mod/network/...
#   mod/patches/...
#   mod/presentation/...
#   mod/ui/...
#   mod/bin/...

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEAM_HELPER_DIR="${SCRIPT_DIR}/steam_helper"
OUTPUT_NAME="${1:-rtv-coop}"
OUTPUT_FILE="${SCRIPT_DIR}/${OUTPUT_NAME}.vmz"

# App ID: 480 (Spacewar) for dev, 1963610 for release
STEAM_APP_ID="480"
if [ "$2" = "release" ]; then
    STEAM_APP_ID="1963610"
fi

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

# Copy Steam SDK libs (Linux .so + Windows .dll for Proton compatibility)
for lib in libsteam_api.so libsteam_api64.so steam_api64.dll; do
    if [ -f "${STEAM_HELPER_DIR}/bin/${lib}" ]; then
        cp -f "${STEAM_HELPER_DIR}/bin/${lib}" "${SCRIPT_DIR}/bin/"
        echo "Included: ${lib}"
    fi
done

# Write app ID into bin/
echo "$STEAM_APP_ID" > "${SCRIPT_DIR}/bin/steam_appid.txt"
echo "Steam App ID: ${STEAM_APP_ID}"

# Clean previous build
rm -f "$OUTPUT_FILE"

# Zip from parent directory:
# - mod.txt at root (mod loader needs this)
# - mod/* with prefix (matches res://mod/ paths in scripts)
cd "$SCRIPT_DIR/.."

# First add mod.txt at root by copying it temporarily
cp mod/mod.txt mod_txt_root_temp
zip "$OUTPUT_FILE" mod_txt_root_temp
# Rename inside the archive to mod.txt
printf "@ mod_txt_root_temp\n@=mod.txt\n" | zipnote -w "$OUTPUT_FILE" 2>/dev/null || {
    # zipnote not available — rebuild with correct name
    rm "$OUTPUT_FILE"
    cd "$SCRIPT_DIR"
    zip "$OUTPUT_FILE" -j mod.txt
    cd "$SCRIPT_DIR/.."
}
rm -f mod_txt_root_temp

# Now add all mod/* files
zip -r "$OUTPUT_FILE" \
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
    -x "mod/**/*.uid" \
    -x "mod/steam_helper/*" \
    -x "mod/README.md" \
    -x "mod/mod.txt"

echo "Built: $OUTPUT_FILE ($(du -h "$OUTPUT_FILE" | cut -f1))"
