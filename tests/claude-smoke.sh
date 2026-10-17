#!/usr/bin/env bash
# Headless smoke tests for kimo's 'claude' launch branch.
#
# Mocked layer (always): a fake 'claude' on PATH records the argv/env that kimo
# passes, so we can assert the invocation contract without launching the TUI:
#   * --model present
#   * ANTHROPIC_BASE_URL / ANTHROPIC_API_BASE point at the resolved host
#   * CLAUDE_CODE_EFFORT_LEVEL and the CLAUDE_CODE_* defaults are exported
#   * ANTHROPIC_API_KEY is scrubbed to 'ollama' for non-plain-local hosts, and
#     only forwards a real ANTHROPIC_API_KEY/AUTH_TOKEN to a plain local daemon
#   * kimo never overrides API_TIMEOUT_MS (claude's own default is 600000 ms)
#   * preamble defaults: window enforcement off, telemetry/auto-updater/MCP
#     server flags - and user-set values for them are honoured
#   * --ctx exports OLLAMA_CONTEXT_LENGTH
#
# Live layer (opt-in, --live): if a real 'claude' and a reachable Ollama host
# are available, run a headless -p turn and require a sane answer. Slow and
# network-dependent, so it is skipped by default.
#
# Usage: tests/claude-smoke.sh [--live]

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_C="$(mktemp -d)"

FAKE_DIR="${TMPDIR_C}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_C}/call.txt"
export CLAUDE_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/claude" <<'FAKE'
#!/usr/bin/env bash
out="${CLAUDE_SMOKE_OUT:?CLAUDE_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-}"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
    printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-}"
    printf 'ANTHROPIC_API_BASE=%s\n' "${ANTHROPIC_API_BASE-}"
    printf 'CLAUDE_CODE_EFFORT_LEVEL=%s\n' "${CLAUDE_CODE_EFFORT_LEVEL-}"
    printf 'CLAUDE_CODE_MAX_OUTPUT_TOKENS=%s\n' "${CLAUDE_CODE_MAX_OUTPUT_TOKENS-}"
    printf 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-}"
    printf 'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=%s\n' "${CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT-}"
    printf 'CLAUDE_DISABLE_TELEMETRY=%s\n' "${CLAUDE_DISABLE_TELEMETRY-}"
    printf 'DO_NOT_TRACK=%s\n' "${DO_NOT_TRACK-}"
    printf 'DISABLE_AUTO_UPDATER=%s\n' "${DISABLE_AUTO_UPDATER-}"
    printf 'ENABLE_CLAUDEAI_MCP_SERVERS=%s\n' "${ENABLE_CLAUDEAI_MCP_SERVERS-}"
    printf 'OLLAMA_CONTEXT_LENGTH=%s\n' "${OLLAMA_CONTEXT_LENGTH-<unset>}"
    printf 'API_TIMEOUT_MS=%s\n' "${API_TIMEOUT_MS-<unset>}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/claude"

# Host ports are deliberately unassigned (9) so no real Ollama is contacted and
# no live model gets unloaded as a launch side effect.
run_launch() { # <host-mode-args...> ; sets CAPTURE
    rm -f "${CAPTURE}"
    PATH="${FAKE_DIR}:${PATH}" "${KIMO}" "$@" launch claude --model kalidroid-27b:latest \
        >/dev/null 2>&1 || true
}
LOCAL_HOST="http://127.0.0.1:9"          # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"     # LAN address, unreachable
TUNNEL_HOST="http://127.0.0.1:11438"     # ssh -L tunnel (loopback but off-box)

SENTINEL="sk-ant-REAL-SENTINEL-do-not-leak"
export ANTHROPIC_API_KEY="${SENTINEL}"
export ANTHROPIC_AUTH_TOKEN="${SENTINEL}"

# Strip ambient Claude Code configuration (this dev box exports all of it):
# otherwise the "default" assertions pass on inherited values and never
# exercise kimo's own defaults. Per-test override checks set their own values.
unset CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_DISABLE_TELEMETRY DO_NOT_TRACK DISABLE_AUTO_UPDATER \
    ENABLE_CLAUDEAI_MCP_SERVERS CLAUDE_CODE_EFFORT_LEVEL OLLAMA_CONTEXT_LENGTH

echo "[*] mocked: invocation contract"
run_launch --host "${LOCAL_HOST}"
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake claude was never exec'd (no capture); cannot assert"
else
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    check "ANTHROPIC_BASE_URL is the host" "${LOCAL_HOST}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
    check "ANTHROPIC_API_BASE is the host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" ANTHROPIC_API_BASE)"
    check "CLAUDE_CODE_EFFORT_LEVEL default" "low" "$(env_val "${CAPTURE}" CLAUDE_CODE_EFFORT_LEVEL)"
    check "CLAUDE_CODE_MAX_OUTPUT_TOKENS default" "8192" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_OUTPUT_TOKENS)"
    check "CLAUDE_CODE_AUTO_COMPACT_WINDOW default" "100000" "$(env_val "${CAPTURE}" CLAUDE_CODE_AUTO_COMPACT_WINDOW)"
    check "unknown-model window enforcement disabled" "1" "$(env_val "${CAPTURE}" CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT)"
    check "telemetry disabled" "1" "$(env_val "${CAPTURE}" CLAUDE_DISABLE_TELEMETRY)"
    check "DO_NOT_TRACK set" "1" "$(env_val "${CAPTURE}" DO_NOT_TRACK)"
    check "auto-updater disabled" "1" "$(env_val "${CAPTURE}" DISABLE_AUTO_UPDATER)"
    check "claude.ai MCP servers off by default" "false" "$(env_val "${CAPTURE}" ENABLE_CLAUDEAI_MCP_SERVERS)"
fi

echo "[*] mocked: api-key scrub"
run_launch --host "${LOCAL_HOST}"
check "plain local host forwards the real key" "${SENTINEL}" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "plain local host keeps ANTHROPIC_AUTH_TOKEN" "${SENTINEL}" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"

( export OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "remote host scrubs ANTHROPIC_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "remote host unsets ANTHROPIC_AUTH_TOKEN" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"

run_launch --host "${REMOTE_HOST}"
check "LAN host scrubs ANTHROPIC_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"

run_launch --host "${TUNNEL_HOST}"
check "ssh -L tunnel host scrubs ANTHROPIC_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"

echo "[*] mocked: effort + timeout passthrough"
CLAUDE_CODE_EFFORT_LEVEL=high run_launch --host "${LOCAL_HOST}"
check "existing CLAUDE_CODE_EFFORT_LEVEL is honoured" "high" "$(env_val "${CAPTURE}" CLAUDE_CODE_EFFORT_LEVEL)"

run_launch --host "${LOCAL_HOST}"
check "kimo does not set API_TIMEOUT_MS (claude default 600000)" "<unset>" "$(env_val "${CAPTURE}" API_TIMEOUT_MS)"

API_TIMEOUT_MS=90000 run_launch --host "${LOCAL_HOST}"
check "user API_TIMEOUT_MS passes through untouched" "90000" "$(env_val "${CAPTURE}" API_TIMEOUT_MS)"

echo "[*] mocked: preamble overrides honoured"
CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=0 run_launch --host "${LOCAL_HOST}"
check "user window-enforcement choice honoured" "0" "$(env_val "${CAPTURE}" CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT)"

ENABLE_CLAUDEAI_MCP_SERVERS=true run_launch --host "${LOCAL_HOST}"
check "user MCP server choice honoured" "true" "$(env_val "${CAPTURE}" ENABLE_CLAUDEAI_MCP_SERVERS)"

echo "[*] mocked: --ctx wiring"
run_launch --host "${LOCAL_HOST}"
check "no OLLAMA_CONTEXT_LENGTH without --ctx" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_CONTEXT_LENGTH)"

rm -f "${CAPTURE}"
PATH="${FAKE_DIR}:${PATH}" "${KIMO}" --host "${LOCAL_HOST}" launch claude --model kalidroid-27b:latest --ctx 32768 \
    >/dev/null 2>&1 || true
check "--ctx 32768 exports OLLAMA_CONTEXT_LENGTH" "32768" "$(env_val "${CAPTURE}" OLLAMA_CONTEXT_LENGTH)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: requires the real claude CLI.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    real_claude="$(PATH="${PATH}" command -v claude || true)"
    host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
    model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
    if [[ -z "${real_claude}" ]]; then
        echo "  SKIP claude CLI not found"
    elif ! curl -s -m 3 "${host}/api/tags" >/dev/null 2>&1; then
        echo "  SKIP no Ollama at ${host}"
    else
        out="${TMPDIR_C}/live.txt"
        if ANTHROPIC_BASE_URL="${host}" ANTHROPIC_API_KEY=ollama \
                API_TIMEOUT_MS=600000 timeout 300 "${real_claude}" \
                -p 'Reply with exactly: PONG' --output-format json \
                --model "${model}" >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(head -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(head -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
