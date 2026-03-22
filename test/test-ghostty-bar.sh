#!/usr/bin/env bash
# test-ghostty-bar.sh — Verify ghostty_bar.lua sends SET-COMPONENTS to a socket.
#
# Starts a mock Unix socket server, launches nvim headlessly with GHOSTTY_SOCKET
# set, waits for SET-COMPONENTS, then validates the JSON payload.
#
# Requires: nvim, python3

set -euo pipefail

# Use the well-known default path to also test the fallback behavior
SOCK="/tmp/ghostty.sock"
PASS=0
FAIL=0
SERVER_PID=""
NVIM_PID=""

cleanup() {
    [[ -n "$NVIM_PID" ]] && kill "$NVIM_PID" 2>/dev/null; wait "$NVIM_PID" 2>/dev/null || true
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$SOCK" /tmp/ghostty.log
}
trap cleanup EXIT

echo "=== ghostty_bar.lua Test ==="

# Start a mock socket server that logs received commands
python3 - "$SOCK" <<'PYEOF' &
import socket, sys, os, time

sock_path = sys.argv[1]
log_path = sock_path.replace(".sock", ".log")

if os.path.exists(sock_path):
    os.unlink(sock_path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(5)
server.settimeout(30)  # 30s total timeout

with open(log_path, "w") as log:
    try:
        while True:
            try:
                conn, _ = server.accept()
                conn.settimeout(5)
                data = conn.recv(8192).decode("utf-8", errors="replace")
                for line in data.strip().split("\n"):
                    if line:
                        log.write(line + "\n")
                        log.flush()
                        # Respond OK to each command
                        try:
                            conn.sendall(b"OK\n")
                        except:
                            pass
                conn.close()
            except socket.timeout:
                break
    except Exception as e:
        log.write(f"ERROR: {e}\n")
    finally:
        server.close()
        try:
            os.unlink(sock_path)
        except:
            pass
PYEOF
SERVER_PID=$!

# Wait for socket
for i in $(seq 1 20); do
    [[ -S "$SOCK" ]] && break
    sleep 0.1
done
if [[ ! -S "$SOCK" ]]; then
    echo "FAIL: Mock socket did not appear"
    exit 1
fi
echo "Mock server PID=$SERVER_PID, socket=$SOCK"

# Launch nvim headlessly with the ghostty_bar plugin
# -u NONE to skip normal config, but load our plugin explicitly
GHOSTTY_SOCKET="$SOCK" nvim --headless \
    -c "set rtp+=$HOME/.config/nvim" \
    -c "lua require('ghostty_bar')" \
    -c "lua vim.o.stl = ' NORMAL  test.lua '" \
    -c "lua require('ghostty_bar').update()" \
    -c "sleep 500m" \
    -c "lua require('ghostty_bar').cleanup()" \
    -c "sleep 500m" \
    -c "qa!" &
NVIM_PID=$!

# Wait for nvim to finish
wait $NVIM_PID 2>/dev/null || true
NVIM_PID=""

# Give server a moment to flush
sleep 0.5

# Kill server
kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null || true
SERVER_PID=""

# Check the log
LOG="/tmp/ghostty.log"
echo ""
echo "--- Received commands ---"
if [[ -f "$LOG" ]]; then
    cat "$LOG"
else
    echo "(no log file)"
fi

echo ""
echo "--- Validation ---"

# Test 1: SET-COMPONENTS was received
if grep -q "SET-COMPONENTS" "$LOG" 2>/dev/null; then
    echo "  PASS: SET-COMPONENTS received"
    PASS=$((PASS + 1))
else
    echo "  FAIL: No SET-COMPONENTS in log"
    FAIL=$((FAIL + 1))
fi

# Test 2: JSON payload contains source with nvim prefix
if grep -q '"source".*"nvim-' "$LOG" 2>/dev/null; then
    echo "  PASS: Source contains nvim PID"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Source missing nvim prefix"
    FAIL=$((FAIL + 1))
fi

# Test 3: JSON payload contains components array
if grep -q '"components".*\[' "$LOG" 2>/dev/null; then
    echo "  PASS: Components array present"
    PASS=$((PASS + 1))
else
    echo "  FAIL: No components array"
    FAIL=$((FAIL + 1))
fi

# Test 4: CLEAR-COMPONENTS was received
if grep -q "CLEAR-COMPONENTS" "$LOG" 2>/dev/null; then
    echo "  PASS: CLEAR-COMPONENTS received on cleanup"
    PASS=$((PASS + 1))
else
    echo "  FAIL: No CLEAR-COMPONENTS"
    FAIL=$((FAIL + 1))
fi

# Test 5: JSON is valid
if python3 -c "
import json, sys
with open('$LOG') as f:
    for line in f:
        if line.startswith('SET-COMPONENTS '):
            payload = line[len('SET-COMPONENTS '):]
            data = json.loads(payload)
            assert 'zone' in data
            assert 'source' in data
            assert 'components' in data
            assert isinstance(data['components'], list)
            print('  PASS: JSON is valid and well-structured')
            sys.exit(0)
print('  FAIL: No valid JSON found')
sys.exit(1)
" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "  FAIL: Invalid JSON structure"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
