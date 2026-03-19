#!/bin/sh
# Build ghostty without requiring full Xcode installation.
# Only needs Xcode Command Line Tools (xcode-select --install).
#
# Usage:
#   ./scripts/build-dev.sh          # Build everything except macOS app
#   ./scripts/build-dev.sh test     # Run tests
#   ./scripts/build-dev.sh lib-vt   # Build only libghostty-vt
set -e

STEP="${1:-install}"

exec zig build "$STEP" \
    -Demit-xcframework=false \
    -Demit-macos-app=false \
    "${@:2}"
