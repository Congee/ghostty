#!/bin/bash
# End-to-end test for the status bar control socket.
# Requires a built Ghostty.app and socat.
# Usage: ./scripts/test-statusbar-e2e.sh
set -euo pipefail

APP="zig-out/Ghostty.app"
BINARY="$APP/Contents/MacOS/Ghostty"
PASS=0
FAIL=0
GHOSTTY_PID=""

cleanup() {
    if [ -n "$GHOSTTY_PID" ] && kill -0 "$GHOSTTY_PID" 2>/dev/null; then
        kill "$GHOSTTY_PID" 2>/dev/null || true
        wait "$GHOSTTY_PID" 2>/dev/null || true
    fi
    rm -f /tmp/ghostty-ctl-*.sock
}
trap cleanup EXIT

if ! command -v socat &>/dev/null; then
    echo "SKIP: socat not installed (brew install socat)"
    exit 0
fi

if [ ! -x "$BINARY" ]; then
    echo "SKIP: $BINARY not found (run: zig build)"
    exit 0
fi

# Clean stale sockets
rm -f /tmp/ghostty-ctl-*.sock

# Launch binary directly (not via 'open') so the control socket works.
GHOSTTY_LOG=1 "$BINARY" 2>/tmp/ghostty-e2e-log.txt &
GHOSTTY_PID=$!

# Wait for control socket to appear and become connectable (up to 15s)
SOCKET=""
for i in $(seq 1 30); do
    # Use /private/tmp because macOS find doesn't follow /tmp symlink reliably
    SOCK_FILE=$(find /private/tmp -maxdepth 1 -name "ghostty-ctl-*.sock" 2>/dev/null | head -1)
    if [ -n "$SOCK_FILE" ]; then
        if echo "PING" | socat -t1 - UNIX-CONNECT:"$SOCK_FILE" >/dev/null 2>&1; then
            SOCKET="$SOCK_FILE"
            break
        fi
    fi
    sleep 0.5
done
if [ -z "$SOCKET" ]; then
    echo "FAIL: no control socket found after 15s"
    echo "Log tail:"
    tail -20 /tmp/ghostty-e2e-log.txt 2>/dev/null || true
    exit 1
fi
echo "Socket: $SOCKET (found after ~$((i / 2))s)"

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

# Test 2: Initial state — at least 1 tab
echo "2. Initial state"
TABS=$(cmd "LIST-TABS")
TAB_COUNT=$(echo "$TABS" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "0")
if [ "$TAB_COUNT" -ge 1 ]; then
    echo "  PASS: at least 1 tab initially (got $TAB_COUNT)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected at least 1 tab, got $TAB_COUNT"
    FAIL=$((FAIL + 1))
fi

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows tab 0" "[0:" "$SB"

# Test 3: RENAME-TAB
echo "3. Rename tab"
cmd "RENAME-TAB myserver" >/dev/null
sleep 0.5

SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows renamed tab" "myserver" "$SB"

# Test 4: SET-COMPONENTS
echo "4. SET-COMPONENTS"
RESP=$(cmd 'SET-COMPONENTS {"zone":"left","source":"test","components":[{"text":" TEST "}]}')
assert_eq "SET-COMPONENTS accepted" "OK" "$RESP"

# Test 5: CLEAR-COMPONENTS
echo "5. CLEAR-COMPONENTS"
RESP=$(cmd "CLEAR-COMPONENTS test")
assert_eq "CLEAR-COMPONENTS accepted" "OK" "$RESP"

# Test 6: GET-FOCUSED
echo "6. GET-FOCUSED"
RESP=$(cmd "GET-FOCUSED")
assert_contains "GET-FOCUSED returns tabs count" '"tabs":' "$RESP"

# Test 7: Unknown command
echo "7. Unknown command"
RESP=$(cmd "FOOBAR")
assert_contains "unknown command returns ERR" "ERR" "$RESP"

# Test 8: SET-STATUS-LEFT
echo "8. SET-STATUS-LEFT"
RESP=$(cmd "SET-STATUS-LEFT hello world")
assert_eq "SET-STATUS-LEFT accepted" "OK" "$RESP"
SB=$(cmd "GET-STATUS-BAR")
assert_contains "status bar shows custom left text" "hello world" "$SB"

# Test 9: CLEAR-STATUS
echo "9. CLEAR-STATUS"
RESP=$(cmd "CLEAR-STATUS")
assert_eq "CLEAR-STATUS accepted" "OK" "$RESP"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
