#!/bin/bash
# Install script for versions
# Compiles versions.swift and installs to /usr/local/bin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/versions.swift"
DEST="/usr/local/bin/versions"

if [ ! -f "$SOURCE" ]; then
    echo "Error: versions.swift not found in $SCRIPT_DIR"
    exit 1
fi

echo "Compiling versions.swift..."
swiftc "$SOURCE" -O -o /tmp/versions_build

echo "Installing to $DEST (may require sudo)..."
if [ -w "$(dirname "$DEST")" ]; then
    mv /tmp/versions_build "$DEST"
else
    sudo mv /tmp/versions_build "$DEST"
fi

chmod +x "$DEST"
echo "Done. Run 'versions --help' to get started."
