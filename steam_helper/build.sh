#!/usr/bin/env bash
# Rebuilds the Linux + Windows steam_helper binaries with symbols and debug
# info stripped (-s -w) and build path information removed (-trimpath).
# Shaves ~33% off each binary — critical because they ship verbatim inside
# the .vmz, so every byte here is a byte on every player's disk.
set -euo pipefail

cd "$(dirname "$0")"

LDFLAGS="-s -w"

echo "Compiling steam_helper_linux..."
GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="$LDFLAGS" -o bin/steam_helper_linux .

echo "Compiling steam_helper.exe..."
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags="$LDFLAGS" -o bin/steam_helper.exe .

ls -lh bin/steam_helper_linux bin/steam_helper.exe
