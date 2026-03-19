#!/bin/bash
# Run daemon build verification. The daemon runs in-process via ghostty +daemon
# so tests are part of the main build.
# Usage: ./scripts/test-daemon.sh
set -euo pipefail

echo "=== Daemon build verification ==="
zig build -Demit-xcframework=false -Demit-macos-app=false
echo "Build passed."
