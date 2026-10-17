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
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
export KIMO_NO_AUTOSCAN=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

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
