#!/usr/bin/env bash
# Headless smoke tests for kimo's 'opencode' launch branch.
#
# Mocked layer (always): a fake 'opencode' on PATH records the argv/env that
# kimo passes, so we can assert the contract without the real binary:
#   * --model present
#   * standard Ollama host env (OLLAMA_HOST, OPENAI_BASE_URL/API_BASE=/v1,
#     ANTHROPIC_BASE_URL, API_BASE)
#   * OPENAI_API_KEY / ANTHROPIC_API_KEY: default ollama; forwarded unchanged
#     to a plain local daemon; scrubbed to 'ollama' for remote/LAN/tunnel hosts
#     (Qwen/Claude-style policy). opencode itself routes via its own provider
#     config and reads no base-url env (verified on opencode 1.19.0), so this is
#     defence-in-depth rather than a live leak fix.
#   * no timeout-env analog is set (opencode has none kimo must raise)
#
# Live layer (opt-in, --live): run a real headless `opencode run` turn through
# kimo, using an ISOLATED $HOME whose opencode.jsonc defines a throwaway
# 'kimo' provider pointing at KIMO_SMOKE_HOST. Slow and network-dependent, so
# it is skipped by default. KIMO_SMOKE_MODEL is the Ollama tag to declare.
#
# Usage: tests/opencode-smoke.sh [--live]

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_A="$(mktemp -d)"

FAKE_DIR="${TMPDIR_A}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_A}/call.txt"
export OPENCODE_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/opencode" <<'FAKE'
#!/usr/bin/env bash
out="${OPENCODE_SMOKE_OUT:?OPENCODE_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'OLLAMA_HOST=%s\n' "${OLLAMA_HOST-<unset>}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-<unset>}"
    printf 'OPENAI_API_BASE=%s\n' "${OPENAI_API_BASE-<unset>}"
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-<unset>}"
    printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-<unset>}"
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-<unset>}"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
    printf 'API_BASE=%s\n' "${API_BASE-<unset>}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/opencode"
# Fake stays on PATH for the whole mocked tier; restored before the live tier.
export PATH="${FAKE_DIR}:${PATH}"

# Unreachable upstream (port 9) so no real Ollama is contacted.
UPSTREAM="http://192.168.1.131:9"
run_launch() {
    rm -f "${CAPTURE}"
    "${KIMO}" --host "${UPSTREAM}" launch opencode \
        --model kalidroid-27b:latest >/dev/null 2>&1 || true
}

echo "[*] mocked: invocation + host env"
run_launch
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake opencode was never exec'd (no capture); cannot assert"
else
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    check "OLLAMA_HOST exported" "${UPSTREAM}" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
    check "OPENAI_BASE_URL ends in /v1" "${UPSTREAM}/v1" "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
    check "OPENAI_API_BASE ends in /v1" "${UPSTREAM}/v1" "$(env_val "${CAPTURE}" OPENAI_API_BASE)"
    check "ANTHROPIC_BASE_URL is the host" "${UPSTREAM}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
    check "API_BASE ends in /v1" "${UPSTREAM}/v1" "$(env_val "${CAPTURE}" API_BASE)"
fi

echo "[*] mocked: api-key scrub (defence-in-depth; opencode reads no base-url env)"
unset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
run_launch
check "OPENAI_API_KEY defaults to ollama" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "ANTHROPIC_API_KEY defaults to ollama" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"

OPENAI_API_KEY="sk-REAL-SENTINEL-do-not-leak" ANTHROPIC_API_KEY="sk-ant-REAL-SENTINEL-do-not-leak" \
    ANTHROPIC_AUTH_TOKEN="t-REAL-SENTINEL-do-not-leak" \
    "${KIMO}" --host http://127.0.0.1:9 launch opencode --model kalidroid-27b:latest >/dev/null 2>&1 || true
check "plain local host keeps OPENAI_API_KEY (sk-REAL-SENTINEL-do-not-leak)" "sk-REAL-SENTINEL-do-not-leak" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "plain local host keeps ANTHROPIC_API_KEY (sk-ant-REAL-SENTINEL-do-not-leak)" "sk-ant-REAL-SENTINEL-do-not-leak" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"

OPENAI_API_KEY="sk-REAL-SENTINEL-do-not-leak" ANTHROPIC_API_KEY="sk-ant-REAL-SENTINEL-do-not-leak" \
    ANTHROPIC_AUTH_TOKEN="t-REAL-SENTINEL-do-not-leak" \
    "${KIMO}" --host "${UPSTREAM}" launch opencode --model kalidroid-27b:latest >/dev/null 2>&1 || true
check "remote host scrubs OPENAI_API_KEY to ollama (ollama)" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "remote host scrubs ANTHROPIC_API_KEY to ollama (ollama)" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "remote host unsets ANTHROPIC_AUTH_TOKEN (<unset>)" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"

OPENAI_API_KEY="sk-REAL-SENTINEL-do-not-leak" \
    "${KIMO}" --host http://192.168.1.131:9 launch opencode --model kalidroid-27b:latest >/dev/null 2>&1 || true
check "LAN host scrubs OPENAI_API_KEY to ollama (ollama)" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: real headless 'opencode run' through kimo, against an
# isolated $HOME whose opencode.jsonc declares a throwaway 'kimo' provider.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless run turn through kimo"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    if ! command -v opencode >/dev/null 2>&1; then
        echo "  SKIP opencode CLI not found"
    else
        host="${KIMO_SMOKE_HOST:-http://192.168.1.131:11434}"
        model="${KIMO_SMOKE_MODEL:-granite-4.2-8b-GGUF:uncensored}"
        smoke_home="${TMPDIR_A}/home"
        mkdir -p "${smoke_home}/.config/opencode"
        cat > "${smoke_home}/.config/opencode/opencode.jsonc" <<CONF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "kimo": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "kimo smoke",
      "options": { "baseURL": "${host}/v1", "apiKey": "ollama" },
      "models": { "${model}": { "name": "${model}", "tool_call": true } }
    }
  },
  "model": "kimo/${model}"
}
CONF
        out="${smoke_home}/run.out"
        # No --host: keep kimo's active_host local so its CUDA-collision
        # unload loop never touches the provider's actual Ollama host.
        # opencode routes via the temp config's provider regardless.
        if HOME="${smoke_home}" timeout 300 "${KIMO}" launch opencode \
                --model "kimo/${model}" run "Reply with exactly: PONG" --pure >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(tail -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(tail -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]