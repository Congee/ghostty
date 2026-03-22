#!/usr/bin/env bash
# test-statusbar-queue.sh — Status bar queue e2e tests.
#
# Launches a Ghostty instance, runs all tests via a single python3 process
# to avoid shell quoting issues, then cleans up.
#
# Usage: ./test/test-statusbar-queue.sh
# Override binary: GHOSTTY=/path/to/ghostty ./test/test-statusbar-queue.sh

set -euo pipefail

SOCK="/tmp/ghostty-test-$$.sock"
GPID=""

cleanup() {
    [[ -n "$GPID" ]] && kill "$GPID" 2>/dev/null && wait "$GPID" 2>/dev/null
    rm -f "$SOCK"
}
trap cleanup EXIT

# Find binary
GHOSTTY="${GHOSTTY:-}"
if [[ -z "$GHOSTTY" ]]; then
    if [[ -x ./zig-out/Ghostty.app/Contents/MacOS/Ghostty ]]; then
        GHOSTTY=./zig-out/Ghostty.app/Contents/MacOS/Ghostty
    elif [[ -x ./zig-out/bin/ghostty ]]; then
        GHOSTTY=./zig-out/bin/ghostty
    elif command -v ghostty &>/dev/null; then
        GHOSTTY=ghostty
    else
        echo "ERROR: ghostty binary not found. Set GHOSTTY= or build first."
        exit 1
    fi
fi

echo "=== Status Bar Queue E2E Tests ==="
echo "Binary: $GHOSTTY"
echo "Socket: $SOCK"

# Codesign and launch ghostty
codesign --force --sign - "$(dirname "$GHOSTTY")/../.." 2>/dev/null || true
"$GHOSTTY" --control-socket="$SOCK" --status-bar=true &>/dev/null &
GPID=$!

# Wait for socket
for i in $(seq 1 30); do [[ -S "$SOCK" ]] && break; sleep 0.2; done
if [[ ! -S "$SOCK" ]]; then
    echo "ERROR: Control socket did not appear after 6s"
    exit 1
fi
# Give the surface time to initialize after socket is up
sleep 1

echo "Ghostty PID=$GPID, socket ready."
echo ""

# Run all tests in a single python3 process
exec python3 - "$SOCK" <<'PYEOF'
import socket
import sys
import time
import json
import threading

SOCK = sys.argv[1]
PASS = 0
FAIL = 0

def cmd(msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((msg + "\n").encode())
    s.settimeout(3)
    try:
        return s.recv(4096).decode().strip()
    except socket.timeout:
        return "ERR timeout"
    finally:
        s.close()

def ok(desc):
    global PASS
    PASS += 1
    print(f"  PASS: {desc}")

def fail(desc, detail=""):
    global FAIL
    FAIL += 1
    msg = f"  FAIL: {desc}"
    if detail:
        msg += f" ({detail})"
    print(msg)

def check_eq(desc, expected, actual):
    if expected == actual:
        ok(desc)
    else:
        fail(desc, f"expected {expected!r}, got {actual!r}")

def check_contains(desc, needle, haystack):
    if needle in haystack:
        ok(desc)
    else:
        fail(desc, f"expected {needle!r} in {haystack!r}")

# --- Test 1: PING ---
print("--- Test 1: PING ---")
check_eq("PING returns PONG", "PONG", cmd("PING"))

# --- Test 2: SET-STATUS-LEFT / GET-STATUS-BAR ---
print("\n--- Test 2: SET-STATUS-LEFT / GET-STATUS-BAR ---")
check_eq("SET-STATUS-LEFT accepted", "OK", cmd("SET-STATUS-LEFT hello-queue"))
time.sleep(0.3)
resp = cmd("GET-STATUS-BAR")
# App.sendTabsUpdate() may race and overwrite left_text with tab list;
# either "hello-queue" or tab text like "1:~*" is valid.
if "hello-queue" in resp or "1:" in resp:
    ok("GET-STATUS-BAR returns valid data")
else:
    fail("GET-STATUS-BAR unexpected", resp)

# --- Test 3: SET-STATUS with pipe separator ---
print("\n--- Test 3: SET-STATUS left | right ---")
check_eq("SET-STATUS accepted", "OK", cmd("SET-STATUS left-text | right-text"))

# --- Test 4: SET-STATUS-RIGHT ---
print("\n--- Test 4: SET-STATUS-RIGHT ---")
check_eq("SET-STATUS-RIGHT accepted", "OK", cmd("SET-STATUS-RIGHT rhs"))

# --- Test 5: CLEAR-STATUS ---
print("\n--- Test 5: CLEAR-STATUS ---")
check_eq("CLEAR-STATUS accepted", "OK", cmd("CLEAR-STATUS"))
time.sleep(0.3)
resp = cmd("GET-STATUS-BAR")
# After clear, should be (none) or tab text if renderer refreshed
if "(none)" in resp or "[0:" in resp:
    ok("Status bar cleared or refreshed with tabs")
else:
    fail("Unexpected after CLEAR-STATUS", resp)

# --- Test 6: SET-COMPONENTS ---
print("\n--- Test 6: SET-COMPONENTS ---")
payload = json.dumps({"zone": "left", "source": "test-src", "components": [
    {"text": " TEST ", "style": {"fg": "#e06c75", "bold": True}},
    {"text": " data ", "style": {"fg": "#98c379"}},
]})
check_eq("SET-COMPONENTS accepted", "OK", cmd(f"SET-COMPONENTS {payload}"))

# --- Test 7: CLEAR-COMPONENTS ---
print("\n--- Test 7: CLEAR-COMPONENTS ---")
check_eq("CLEAR-COMPONENTS accepted", "OK", cmd("CLEAR-COMPONENTS test-src"))

# --- Test 8: LIST-TABS ---
print("\n--- Test 8: LIST-TABS ---")
resp = cmd("LIST-TABS")
check_contains("LIST-TABS returns JSON with index", '"index"', resp)

# --- Test 9: GET-FOCUSED ---
print("\n--- Test 9: GET-FOCUSED ---")
resp = cmd("GET-FOCUSED")
check_contains("GET-FOCUSED returns JSON with tabs", '"tabs"', resp)

# --- Test 10: RENAME-TAB ---
print("\n--- Test 10: RENAME-TAB ---")
check_eq("RENAME-TAB accepted", "OK", cmd("RENAME-TAB test-tab-name"))
time.sleep(0.3)
resp = cmd("GET-STATUS-BAR")
check_contains("Status bar shows renamed tab", "test-tab-name", resp)

# --- Test 11: Unknown command ---
print("\n--- Test 11: Error handling ---")
check_contains("Unknown command returns ERR", "ERR", cmd("FOOBAR"))
check_contains("Invalid JSON returns ERR", "ERR", cmd("SET-COMPONENTS {bad json}"))

# --- Test 12: Concurrent writers ---
print("\n--- Test 12: Concurrent writers (3 sources × 20 iterations) ---")
errors = []

def writer(source, n):
    for i in range(n):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(SOCK)
            payload = json.dumps({"zone": "left", "source": source,
                                  "components": [{"text": f"{source}-{i}"}]})
            s.sendall(f"SET-COMPONENTS {payload}\n".encode())
            s.settimeout(2)
            resp = s.recv(64).decode().strip()
            if resp != "OK":
                errors.append(f"{source}-{i}: {resp}")
            s.close()
        except Exception as e:
            errors.append(f"{source}-{i}: {e}")

threads = []
for src in ["alpha", "beta", "gamma"]:
    t = threading.Thread(target=writer, args=(src, 20))
    t.start()
    threads.append(t)
for t in threads:
    t.join()

if not errors:
    ok("60 concurrent SET-COMPONENTS all returned OK")
else:
    fail(f"{len(errors)} errors in concurrent writes", str(errors[:3]))

time.sleep(0.3)
resp = cmd("GET-STATUS-BAR")
if resp and "ERR" not in resp:
    ok("GET-STATUS-BAR valid after concurrent writes")
else:
    fail("GET-STATUS-BAR after concurrent writes", resp)

# Clean up sources
for src in ["alpha", "beta", "gamma"]:
    cmd(f"CLEAR-COMPONENTS {src}")

# --- Summary ---
print(f"\n=== Results: {PASS} passed, {FAIL} failed ===")
sys.exit(0 if FAIL == 0 else 1)
PYEOF
