#!/bin/bash
# Test the status bar component protocol end-to-end.
# Requires: ghostty running with status-bar=true, socat installed.
# Usage: ./scripts/test-statusbar.sh
set -euo pipefail

SOCKET="${GHOSTTY_SOCKET:-/tmp/ghostty.sock}"

if ! command -v socat &>/dev/null; then
    echo "socat not found. Install with: brew install socat"
    exit 1
fi

echo "=== Status Bar Component Tests ==="
echo "Socket: $SOCKET"
echo ""

# Test 1: PING
echo -n "1. PING... "
RESP=$(echo "PING" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "PONG" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 2: SET-COMPONENTS left zone
echo -n "2. SET-COMPONENTS left... "
RESP=$(echo 'SET-COMPONENTS {"zone":"left","source":"test","components":[{"text":" N ","style":{"fg":"#e06c75","bold":true}},{"text":" main ","style":{"fg":"#98c379","bg":"#3e4452"}},{"text":" test.lua ","style":{"fg":"#abb2bf"}}]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 3: SET-COMPONENTS right zone with priority
echo -n "3. SET-COMPONENTS right with priority... "
RESP=$(echo 'SET-COMPONENTS {"zone":"right","source":"test","components":[{"text":" 73% ","style":{"fg":"#61afef","italic":true},"priority":50},{"text":" utf-8 ","style":{"fg":"#56b6c2"},"priority":200}]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 4: SET-COMPONENTS with click
echo -n "4. SET-COMPONENTS with click... "
RESP=$(echo 'SET-COMPONENTS {"zone":"left","source":"test-click","components":[{"text":" [git] ","style":{"fg":"#c678dd"},"click":{"id":"branch","action":"notify"}}]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 5: LIST-TABS
echo -n "5. LIST-TABS... "
RESP=$(echo "LIST-TABS" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if echo "$RESP" | grep -q '"index"'; then echo "OK: $RESP"; else echo "FAIL: $RESP"; fi

# Test 6: GET-FOCUSED
echo -n "6. GET-FOCUSED... "
RESP=$(echo "GET-FOCUSED" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if echo "$RESP" | grep -q '"tabs"'; then echo "OK: $RESP"; else echo "FAIL: $RESP"; fi

# Test 7: RENAME-TAB
echo -n "7. RENAME-TAB... "
RESP=$(echo "RENAME-TAB dev-server" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 8: CLEAR-COMPONENTS
echo -n "8. CLEAR-COMPONENTS... "
RESP=$(echo "CLEAR-COMPONENTS test" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 9: Empty components array
echo -n "9. Empty components... "
RESP=$(echo 'SET-COMPONENTS {"zone":"left","source":"empty","components":[]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if [ "$RESP" = "OK" ]; then echo "OK"; else echo "FAIL: $RESP"; fi

# Test 10: Invalid JSON
echo -n "10. Invalid JSON... "
RESP=$(echo 'SET-COMPONENTS {bad json}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
if echo "$RESP" | grep -q "ERR"; then echo "OK (rejected)"; else echo "FAIL: $RESP"; fi

echo ""
echo "=== Visual check ==="
echo "Setting styled components for 5 seconds..."

# Set a rich status bar to visually verify
echo 'SET-COMPONENTS {"zone":"left","source":"demo","components":[{"text":" NORMAL ","style":{"fg":"#282c34","bg":"#98c379","bold":true}},{"text":" main ","style":{"fg":"#e06c75"}},{"text":" ~/dev/ghostty ","style":{"fg":"#61afef"}}]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null
echo 'SET-COMPONENTS {"zone":"right","source":"demo","components":[{"text":" utf-8 ","style":{"fg":"#56b6c2"}},{"text":" 42:7 ","style":{"fg":"#c678dd","bold":true}},{"text":" 73% ","style":{"fg":"#e5c07b"}}]}' | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null

echo "Look at the status bar — you should see colored segments."
echo "Left: [NORMAL] [main] [~/dev/ghostty]"
echo "Right: [utf-8] [42:7] [73%]"
sleep 5

# Clean up
echo "CLEAR-COMPONENTS demo" | socat - UNIX-CONNECT:"$SOCKET" 2>/dev/null
echo "Cleaned up."
