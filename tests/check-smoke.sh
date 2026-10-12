#!/usr/bin/env bash
# Headless smoke tests for kimo's 'check' and 'ping' connectivity diagnostics.
#
# Validates:
#   * Execution sanity without Python NameError or syntax faults
#   * Output table structure and headers
#   * Structured JSON schema output (--json)
#   * Local routing flag (--local)
#   * Multi-host and custom target routing (--host)
#   * Offline target graceful handling
#
# Usage: tests/check-smoke.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

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

check_not_contains() {
    local label="$1" needle="$2" actual="$3"
    if [[ "${actual}" != *"${needle}"* ]]; then
        echo "  PASS ${label}"
        pass=$((pass + 1))
    else
        echo "  FAIL ${label}: '${actual}' unexpectedly contains '${needle}'"
        fail=$((fail + 1))
    fi
}

echo "=== Kimo Check & Ping Smoke Tests ==="

# [1] Execution sanity (no Python NameError or syntax faults)
echo "[1] Embedded Python runtime execution"
CHECK_OUT="$("${KIMO}" check 2>&1)"
check_not_contains "check does not crash with NameError" "NameError" "${CHECK_OUT}"
check_not_contains "check does not crash with Traceback" "Traceback" "${CHECK_OUT}"
check_match "check outputs header table" "(CONNECTIVITY|TARGET|STATUS)" "${CHECK_OUT}"

PING_OUT="$("${KIMO}" ping 2>&1)"
check_not_contains "ping executes without traceback" "Traceback" "${PING_OUT}"
check_match "ping outputs status" "(ONLINE|OFFLINE)" "${PING_OUT}"

# [2] Structured JSON schema
echo "[2] Structured JSON output (--json)"
JSON_OUT="$("${KIMO}" check --json 2>/dev/null)"
IS_VALID_JSON="$(echo "${JSON_OUT}" | jq -e 'if type == "array" and length > 0 then "valid" else "invalid" end' 2>/dev/null || echo "invalid")"
check "check --json emits non-empty array" "valid" "${IS_VALID_JSON//\"/}"

HAS_HOST_KEY="$(echo "${JSON_OUT}" | jq -e '.[0] | has("host") and has("url") and has("status")' 2>/dev/null || echo "false")"
check "JSON object contains host, url, status keys" "true" "${HAS_HOST_KEY}"

# [3] Host filtering flags (--local, --host)
echo "[3] Host filtering flags (--local, --host)"
LOCAL_JSON="$("${KIMO}" --local check --json 2>/dev/null)"
LOCAL_COUNT="$(echo "${LOCAL_JSON}" | jq 'length' 2>/dev/null || echo "0")"
check "check --local restricts to single host row" "1" "${LOCAL_COUNT}"

# [4] Custom host routing and offline error handling
echo "[4] Custom host routing and offline error handling"
CUSTOM_JSON="$("${KIMO}" --host http://127.0.0.1:54321 check --json 2>/dev/null)"
CUSTOM_STATUS="$(echo "${CUSTOM_JSON}" | jq -r '.[0].status' 2>/dev/null || echo "")"
check "offline target reports offline status" "offline" "${CUSTOM_STATUS}"

echo ""
echo "check smoke: ${pass} passed, ${fail} failed"
(( fail == 0 )) || exit 1
