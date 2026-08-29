#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX_COMMIT="ae7fbce99f98c98df5ccf915e548dd080d33cfa8"
SDK_DIR="$ROOT/vendor/CmuxExtensionKit"
STAMP="$SDK_DIR/.cmux-commit"
FETCH_DIR="$ROOT/vendor/.cmux-sdk-fetch"
ARCHIVE="$ROOT/vendor/.cmux-sdk.tar.gz"

if [[ -f "$STAMP" ]] && [[ "$(<"$STAMP")" == "$CMUX_COMMIT" ]]; then
    echo "CmuxExtensionKit already pinned at $CMUX_COMMIT"
    exit 0
fi

mkdir -p "$ROOT/vendor"
rm -rf -- "$FETCH_DIR" "$SDK_DIR"
rm -f -- "$ARCHIVE"
mkdir -p "$FETCH_DIR"

curl -fsSL \
    "https://github.com/manaflow-ai/cmux/archive/$CMUX_COMMIT.tar.gz" \
    -o "$ARCHIVE"
tar -xzf "$ARCHIVE" -C "$FETCH_DIR" \
    --strip-components=3 \
    "cmux-$CMUX_COMMIT/Packages/macOS/CmuxExtensionKit"
mv "$FETCH_DIR/CmuxExtensionKit" "$SDK_DIR"
printf '%s\n' "$CMUX_COMMIT" > "$STAMP"
rm -rf -- "$FETCH_DIR"
rm -f -- "$ARCHIVE"

echo "Fetched CmuxExtensionKit at $CMUX_COMMIT"
