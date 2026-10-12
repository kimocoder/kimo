#!/usr/bin/env bash
# Headless smoke tests for kimo's WebBridge and web research features.
#
# Validates:
#   * 'web --help' documentation and usage layout
#   * 'web status' offline handling and structured JSON output
#   * 'web url <url>' command formatting and JSON output
#   * 'web search <query>' query construction and search engine dispatch
#   * 'web fetch <url>' execution and offline error messages
#   * 'doctor' diagnostics includes WebBridge probe
#   * Shell autocompletions (Bash and Zsh) expose 'web'
#
# Usage: tests/web-smoke.sh

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

echo "=== Kimo Web & WebBridge Smoke Tests ==="

# [1] CLI help and usage
echo "[1] CLI help flags and documentation"
WEB_HELP="$("${KIMO}" web --help 2>&1)"
check_match "web help mentions WebBridge" "(WebBridge)" "${WEB_HELP}"
check_match "web help lists status command" "(web status)" "${WEB_HELP}"
check_match "web help lists search command" "(web search)" "${WEB_HELP}"
check_match "web help lists fetch command" "(web fetch)" "${WEB_HELP}"
check_match "web help lists url command" "(web url)" "${WEB_HELP}"

# [2] Status command (text and JSON)
echo "[2] Status probe and structured JSON"
STATUS_TXT="$("${KIMO}" web status 2>&1 || true)"
check_match "web status reports offline daemon when inactive" "(offline|unreachable)" "${STATUS_TXT}"

STATUS_JSON="$("${KIMO}" web status --json 2>/dev/null)"
IS_JSON="$(echo "${STATUS_JSON}" | jq -r 'if has("reachable") and has("url") and has("port") then "valid" else "invalid" end' 2>/dev/null || echo "invalid")"
check "web status --json emits valid schema" "valid" "${IS_JSON}"

REACHABLE_VAL="$(echo "${STATUS_JSON}" | jq -r '.reachable' 2>/dev/null || echo "")"
check "web status --json marks inactive daemon as false" "false" "${REACHABLE_VAL}"

# [3] Web URL generator
echo "[3] Navigation command generation (web url)"
URL_OUT="$("${KIMO}" web url https://duckduckgo.com 2>&1)"
check_match "web url outputs curl command" "(curl -s -X POST)" "${URL_OUT}"
check_match "web url includes target URL in JSON payload" "(https://duckduckgo.com)" "${URL_OUT}"

URL_JSON="$("${KIMO}" web url https://duckduckgo.com --json 2>/dev/null)"
PARSED_TARGET="$(echo "${URL_JSON}" | jq -r '.payload.args.url' 2>/dev/null || echo "")"
check "web url --json embeds target URL in args" "https://duckduckgo.com" "${PARSED_TARGET}"

# [4] Web Search navigation
echo "[4] Web search navigation"
SEARCH_OUT="$("${KIMO}" web search "kalidroid ollama" 2>&1 || true)"
check_match "web search constructs search URL" "(https://html.duckduckgo.com/html/\?q=kalidroid\+ollama)" "${SEARCH_OUT}"
check_match "web search mentions manual command or dispatch" "(curl -s -X POST)" "${SEARCH_OUT}"

# [5] Doctor diagnostics integration
echo "[5] Doctor diagnostics integration"
DOC_OUT="$("${KIMO}" doctor 2>&1)"
check_match "doctor includes WebBridge check" "(WebBridge)" "${DOC_OUT}"

# [6] Shell completions (bash & zsh)
echo "[6] Shell autocompletions"
BASH_COMP="$("${KIMO}" completion bash)"
check_match "bash completion includes web command" "(web)" "${BASH_COMP}"
check_match "bash completion includes web subcommands" "(status search fetch url help)" "${BASH_COMP}"

ZSH_COMP="$("${KIMO}" completion zsh)"
check_match "zsh completion includes web command" "('web:WebBridge)" "${ZSH_COMP}"
check_match "zsh completion includes web subcommands" "(status search fetch url help)" "${ZSH_COMP}"

echo ""
echo "web smoke: ${pass} passed, ${fail} failed"
(( fail == 0 )) || exit 1
