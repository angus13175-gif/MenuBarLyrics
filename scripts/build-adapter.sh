#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ADAPTER_SRC="$PROJECT_DIR/third-party/mediaremote-adapter"
BUILD_DIR="$PROJECT_DIR/build-adapter"
OUTPUT_DIR="$PROJECT_DIR/MenuBarLyrics/Resources"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

cmake -S "$ADAPTER_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64"

cmake --build "$BUILD_DIR" --config Release

# Copy framework to Resources
cp -R "$BUILD_DIR/MediaRemoteAdapter.framework" "$OUTPUT_DIR/"

# Remove AppleDouble ._ files created by the ExFAT filesystem; codesign
# treats them as unsigned code objects and fails with "code object is not
# signed at all" / "Operation not permitted".
find "$OUTPUT_DIR/MediaRemoteAdapter.framework" -name "._*" -delete
dot_clean "$OUTPUT_DIR/MediaRemoteAdapter.framework" 2>/dev/null || true

# Ad-hoc sign the framework
codesign --force --sign - "$OUTPUT_DIR/MediaRemoteAdapter.framework"

echo "Framework built and signed at $OUTPUT_DIR/MediaRemoteAdapter.framework"
