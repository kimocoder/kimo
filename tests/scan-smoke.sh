#!/usr/bin/env bash
# Headless smoke tests for kimo's 'scan' and 'init' discovery commands.
#
# Validates:
#   * 'scan --help' and 'init --help' flag exposure (-i, --interactive, --save, --set-remote)
#   * JSON output structured schema
#   * '--set-remote' persistence to config
#   * Interactive candidate menu selection (-i) via stdin pipe
#   * Dynamic discovery without hardcoded remote IP addresses
#   * First-run / unreachable remote auto-discovery prompt
#
# Usage: tests/scan-smoke.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

TMPDIR_A="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_A}"; }
trap cleanup EXIT

pass=0
fail=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "  PASS ${label} (${actual})"
        pass=$((pass + 1))
    else
        echo "  FAIL ${label}: expected '${expected}', got '${actual}'"
        fail=$((fail + 1))
    fi
}

check_match() {
    local label="$1" regex="$2" actual="$3"
    if [[ "${actual}" =~ ${regex} ]]; then
        echo "  PASS ${label}"
        pass=$((pass + 1))
    else
        echo "  FAIL ${label}: '${actual}' did not match '${regex}'"
        fail=$((fail + 1))
    fi
}

echo "=== Kimo Scan & Init Discovery Smoke Tests ==="

# 1. CLI help flags
echo "[1] CLI help flags and documentation"
SCAN_HELP="$("${KIMO}" scan --help)"
INIT_HELP="$("${KIMO}" init --help)"

check_match "scan help mentions -i/--interactive" "(-i, --interactive)" "${SCAN_HELP}"
check_match "scan help mentions --save" "(--save)" "${SCAN_HELP}"
check_match "scan help mentions --set-remote" "(--set-remote)" "${SCAN_HELP}"
check_match "init help mentions discovery wizard" "(discovery wizard)" "${INIT_HELP}"

# 2. JSON structured scan
echo "[2] Structured JSON scan output"
SCAN_JSON="$("${KIMO}" scan 127.0.0.1 -p 11434 --json)"
JSON_VALID=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
assert isinstance(data, list)
assert len(data) >= 1
assert "endpoint" in data[0]
assert "models" in data[0]
print("valid")
' "${SCAN_JSON}" 2>/dev/null || echo "invalid")
check "JSON payload is valid and structured" "valid" "${JSON_VALID}"

# 3. --set-remote configuration update
echo "[3] Config persistence via --set-remote"
CFG_TEST="${TMPDIR_A}/kimo_config_set"
touch "${CFG_TEST}"
KIMO_CONFIG_FILE="${CFG_TEST}" "${KIMO}" scan --set-remote 192.168.1.200:11434 --json >/dev/null
SAVED_REMOTE=$(grep -E "^remote_url=" "${CFG_TEST}" 2>/dev/null | cut -d= -f2- || true)
check "--set-remote persists to config" "http://192.168.1.200:11434" "${SAVED_REMOTE}"

# 4. Interactive candidate selection (-i)
echo "[4] Interactive candidate menu selection"
CFG_INTERACTIVE="${TMPDIR_A}/kimo_config_interactive"
touch "${CFG_INTERACTIVE}"
echo "1" | KIMO_CONFIG_FILE="${CFG_INTERACTIVE}" "${KIMO}" scan 127.0.0.1 -p 11434 -i >/dev/null
INTERACTIVE_SAVED=$(grep -E "^remote_url=" "${CFG_INTERACTIVE}" 2>/dev/null | cut -d= -f2- || true)
check "interactive selection 1 sets remote_url" "http://127.0.0.1:11434" "${INTERACTIVE_SAVED}"

# 5. Interactive cancel
echo "[5] Interactive menu cancellation"
CFG_CANCEL="${TMPDIR_A}/kimo_config_cancel"
echo "remote_url=http://orig.local:11434" > "${CFG_CANCEL}"
echo "q" | KIMO_CONFIG_FILE="${CFG_CANCEL}" "${KIMO}" scan 127.0.0.1 -p 11434 -i >/dev/null
CANCEL_VAL=$(grep -E "^remote_url=" "${CFG_CANCEL}" 2>/dev/null | cut -d= -f2- || true)
check "interactive 'q' leaves remote_url unchanged" "http://orig.local:11434" "${CANCEL_VAL}"

# 6. Verify no hardcoded 192.168.1.131 in script
echo "[6] Elimination of hardcoded IP addresses"
HARDCODED_COUNT=$(grep -c "192\.168\.1\.131" "${KIMO}" || true)
check "zero hardcoded occurrences of 192.168.1.131 in kimo" "0" "${HARDCODED_COUNT}"

# 7. Unreachable remote auto-scan prompt in TTY
echo "[7] Unreachable remote auto-discovery prompt"
PROMPT_OUT=$(python3 -c '
import pty, os, subprocess

master, slave = pty.openpty()
env = dict(os.environ, 
    KIMO_CONFIG_FILE="'"${TMPDIR_A}/empty_cfg"'",
    REMOTE_HOST_IP="192.0.2.1",
    OLLAMA_REMOTE_URL="http://192.0.2.1:11434",
    OLLAMA_LOCAL_URL="http://127.0.0.1:11434"
)
with open("'"${TMPDIR_A}/empty_cfg"'", "w") as f:
    f.write("# empty\n")

proc = subprocess.Popen(["'"${KIMO}"'", "--remote", "hosts"], stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)
os.write(master, b"n\n")
out = b""
while True:
    try:
        chunk = os.read(master, 1024)
        if not chunk: break
        out += chunk
    except OSError:
        break
proc.wait()
os.close(master)
print(out.decode("utf-8", errors="replace"))
' 2>/dev/null || true)

check_match "auto-discovery prompt shown for unconfigured unreachable remote" "Would you like to scan your network" "${PROMPT_OUT}"

echo ""
echo "Summary: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]] || exit 1
