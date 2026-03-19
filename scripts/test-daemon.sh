#!/bin/bash
# Run all daemon-related tests. Suitable for CI or local verification.
# Usage: ./scripts/test-daemon.sh
set -euo pipefail

echo "=== Daemon tests ==="

echo "--- VtParser (35 tests) ---"
zig test src/daemon/VtParser.zig -lc

echo "--- DaemonClient + integration (44 tests) ---"
zig test src/daemon/DaemonClient.zig -lc

echo "--- CLI integration (41 tests) ---"
zig test src/daemon/cli_test.zig -lc

echo "--- Build daemon binary ---"
zig build daemon -Demit-xcframework=false -Demit-macos-app=false

echo ""
echo "All daemon tests passed."
