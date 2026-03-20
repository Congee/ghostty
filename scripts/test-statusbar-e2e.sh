#!/bin/bash
# End-to-end test for the status bar. Requires a built Ghostty.app and socat.
# Usage: ./scripts/test-statusbar-e2e.sh
set -euo pipefail

APP="zig-out/Ghostty.app"
BINARY="$APP/Contents/MacOS/Ghostty"
PASS=0
FAIL=0

if ! command -v socat &>/dev/null; then
    echo "SKIP: socat not installed (brew install socat)"
    exit 0
fi

if [ ! -x "$BINARY" ]; then
    echo "SKIP: $BINARY not found (run: zig build)"
    exit 0
fi

# Kill any existing instance and clean stale sockets
pkill -f Ghostty 2>/dev/null || true
sleep 1
rm -f /tmp/ghostty-ctl-*.sock 2>/dev/null || true

# Launch ghostty
open "$APP"

# Wait for control socket to appear (up to 10s)
SOCKET=""
for i in $(seq 1 20); do
    SOCKET=$(ls /tmp/ghostty-ctl-*.sock 2>/dev/null | head -1)
    if [ -n "$SOCKET" ]; then
        # Verify it's connectable
        if echo "PING" | socat -t1 - UNIX-CONNECT:"$SOCKET" >/dev/null 2>&1; then
            break
        fi
        SOCKET=""
    fi
    sleep 0.5
done
if [ -z "$SOCKET" ]; then
    echo "FAIL: no control socket found after 10s"
    echo "Is status-bar=true in ~/.config/ghostty/config?"
    pkill -f Ghostty 2>/dev/null || true
    exit 1
fi
echo "Socket: $SOCKET"

cmd() {
    echo "$1" | socat -t2 - UNIX-CONNECT:"$SOCKET" 2>/dev/null
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected to contain '$needle')"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_count() {
    local desc="$1" expected="$2" json="$3"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "error")
    assert_eq "$desc" "$expected" "$actual"
}

echo ""
echo "=== Status Bar E2E Tests ==="
echo ""

# Test 1: PING
echo "1. Control socket connectivity"
RESP=$(cmd "PING")
assert_eq "PING returns PONG" "PONG" "$RESP"

# Test 2: Initial state — 1 tab
echo "2. Initial state"
TABS=$(cmd "LIST-TABS")
assert_count "1 tab initially" "1" "$TABS"

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows tab 0" "[0:" "$SB"

# Test 3: Open a new tab
echo "3. Open new tab (cmd+t)"
osascript -e 'tell application "System Events" to keystroke "t" using command down' 2>/dev/null
sleep 2

TABS=$(cmd "LIST-TABS")
assert_count "2 tabs after cmd+t" "2" "$TABS"

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows tab 0" "[0:" "$SB"
assert_contains "status bar shows tab 1" "[1:" "$SB"

# Test 4: Open another tab
echo "4. Open third tab"
osascript -e 'tell application "System Events" to keystroke "t" using command down' 2>/dev/null
sleep 2

TABS=$(cmd "LIST-TABS")
assert_count "3 tabs after second cmd+t" "3" "$TABS"

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows 3 tabs" "[2:" "$SB"

# Test 5: Close a tab
echo "5. Close tab (cmd+w)"
osascript -e 'tell application "System Events" to keystroke "w" using command down' 2>/dev/null
sleep 2

TABS=$(cmd "LIST-TABS")
assert_count "2 tabs after cmd+w" "2" "$TABS"

SB=$(cmd "GET-STATUS-BAR")
# After closing, should NOT have [2:
if echo "$SB" | grep -qF "[2:"; then
    echo "  FAIL: status bar still shows 3 tabs after close"
    echo "    actual: $SB"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: status bar updated after tab close"
    PASS=$((PASS + 1))
fi

# Test 6: RENAME-TAB
echo "6. Rename tab"
cmd "RENAME-TAB myserver" >/dev/null
sleep 1

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows renamed tab" "myserver" "$SB"

# Test 7: SET-COMPONENTS
echo "7. SET-COMPONENTS"
RESP=$(cmd 'SET-COMPONENTS {"zone":"left","source":"test","components":[{"text":" TEST "}]}')
assert_eq "SET-COMPONENTS accepted" "OK" "$RESP"

# Test 8: CLEAR-COMPONENTS
echo "8. CLEAR-COMPONENTS"
RESP=$(cmd "CLEAR-COMPONENTS test")
assert_eq "CLEAR-COMPONENTS accepted" "OK" "$RESP"

# Test 9: GET-FOCUSED
echo "9. GET-FOCUSED"
RESP=$(cmd "GET-FOCUSED")
assert_contains "GET-FOCUSED returns tabs count" '"tabs":' "$RESP"

# Cleanup
echo ""
echo "Cleaning up..."
pkill -f Ghostty 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
