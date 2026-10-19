#!/usr/bin/env bash
# Headless smoke tests for the DashScope cloud provider
# ('launch --provider dashscope'): intl compatible-mode routing, the
# zero-footprint kimi env channel, credential handling and precedence.
#
# Asserts:
#   * dry-run reports the DashScope host, default model, context and masked key
#   * an explicit --model wins and a dashscope/ namespace is stripped
#   * a missing key (or kimo's own 'ollama' placeholder) fails with a hint
#   * MODELSTUDIO_API_KEY is accepted as a fallback credential
#   * kimi receives the KIMI_MODEL_* env channel (name, wire type, base URL,
#     key, context, reasoning key) and no kimi config.toml is written
#   * --ctx overrides the context window end to end
#   * unsupported CLIs are rejected and config/flag precedence holds
#   * a remote Ollama host never sees the DashScope key
#   * the hosted path never probes Ollama
#
# Usage: tests/dashscope-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# A developer shell may export a real DashScope key; the missing-key checks
# below must see an empty environment.
unset DASHSCOPE_API_KEY MODELSTUDIO_API_KEY

FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/dashscope-call.txt"
mkdir -p "${FAKE_BIN}"
export DASHSCOPE_TEST_CAPTURE="${CAPTURE}"
cat > "${FAKE_BIN}/kimi" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in KIMI_MODEL_NAME KIMI_MODEL_API_KEY KIMI_MODEL_PROVIDER_TYPE KIMI_MODEL_BASE_URL \
        KIMI_MODEL_MAX_CONTEXT_SIZE KIMI_MODEL_CAPABILITIES KIMI_MODEL_REASONING_KEY \
        KIMI_MODEL_THINKING_EFFORT OLLAMA_HOST OPENAI_BASE_URL DASHSCOPE_API_KEY; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${DASHSCOPE_TEST_CAPTURE:?}"
printf '{"native":true}\n'
exit "${DASHSCOPE_TEST_RC:-0}"
SH
chmod +x "${FAKE_BIN}/kimi"
export PATH="${FAKE_BIN}:${PATH}"

KEY="sk-dashscope-fixture-12345"
HOST="https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

echo "[*] [1] Routing and dry-run report"
dry=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "provider reported" "provider: dashscope" "${dry}"
check_contains "host is the intl compatible-mode surface" "host   : ${HOST}" "${dry}"
check_contains "default model is qwen3.8-max" "model  : qwen3.8-max" "${dry}"
check_contains "kimi argv carries no -m" "argv   : kimi" "${dry}"
check_contains "evict is n/a" "evict  : n/a" "${dry}"
check_contains "context defaults to 1000000" "context: 1000000 tokens" "${dry}"
check_contains "the key is masked" "secret : DASHSCOPE_API_KEY <kept: real value, DashScope key>" "${dry}"
check_not_contains "the dry run never prints the key" "${KEY}" "${dry}"

echo "[*] [2] Model selection"
dry=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --model qwen3-coder-plus --dry-run)
check_contains "explicit model wins" "model  : qwen3-coder-plus" "${dry}"
dry=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --model dashscope/qwen3-max --dry-run)
check_contains "dashscope/ namespace is stripped" "model  : qwen3-max" "${dry}"
dry=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --ctx 12345 --dry-run)
check_contains "--ctx overrides the context window" "context: 12345 tokens" "${dry}"

echo "[*] [3] Credential handling"
rc=0
nokey=$("${KIMO}" launch kimi --provider dashscope --dry-run 2>&1) || rc=$?
check "a missing key fails" 1 "${rc}"
check_contains "the error names the variable" "DASHSCOPE_API_KEY" "${nokey}"
rc=0
DASHSCOPE_API_KEY=ollama "${KIMO}" launch kimi --provider dashscope --dry-run >/dev/null 2>&1 || rc=$?
check "kimo's own placeholder is not sent to DashScope" 1 "${rc}"
dry=$(MODELSTUDIO_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "MODELSTUDIO_API_KEY is accepted" "provider: dashscope" "${dry}"
rc=0
only_sp=$(DASHSCOPE_API_KEY=sk-sp-dead-token-plan-fixture "${KIMO}" launch kimi --provider dashscope --dry-run 2>&1) || rc=$?
check "a lone token-plan key fails" 1 "${rc}"
check_contains "the failure names the token-plan class" "token-plan" "${only_sp}"
mixed=$(DASHSCOPE_API_KEY=sk-sp-dead-token-plan-fixture MODELSTUDIO_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "a token-plan key defers to the next variable" "provider: dashscope" "${mixed}"

echo "[*] [4] Zero-footprint kimi env channel"
DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope >/dev/null 2>&1
check "kimi receives the model name" "qwen3.8-max" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "kimi receives the openai wire type" "openai" "$(env_val "${CAPTURE}" KIMI_MODEL_PROVIDER_TYPE)"
check "kimi receives the DashScope base URL" "${HOST}" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
check "kimi receives the real key" "${KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "kimi receives the documented context" "1000000" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check "kimi receives the reasoning key" "reasoning_content" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "no Ollama host is exported" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
check "no kimi config is written" no "$([[ -f "${HOME}/.kimi-code/config.toml" ]] && echo yes || echo no)"
DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --ctx 4096 >/dev/null 2>&1
check "--ctx reaches the env channel" "4096" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
DASHSCOPE_API_KEY=sk-sp-dead-token-plan-fixture MODELSTUDIO_API_KEY="${KEY}" \
    "${KIMO}" launch kimi --provider dashscope >/dev/null 2>&1
check "the skipped token-plan key never reaches kimi" "${KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"

echo "[*] [5] Precedence, supported CLIs and scrubbing"
rc=0
unsupported=$("${KIMO}" launch claude --provider dashscope --dry-run 2>&1) || rc=$?
check "unsupported cloud CLI rejected" 1 "${rc}"
check_contains "the rejection names the supported CLIs" "kimi" "${unsupported}"
"${KIMO}" config set cloud_provider dashscope >/dev/null
check "config accepts dashscope" dashscope "$("${KIMO}" config get cloud_provider)"
dry=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --dry-run)
check_contains "the configured backend is used" "provider: dashscope" "${dry}"
"${KIMO}" config unset cloud_provider >/dev/null
forced=$(DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch kimi --provider ollama --dry-run)
check_contains "explicit Ollama wins over credentials and config" "provider: ollama" "${forced}"
DASHSCOPE_API_KEY="${KEY}" "${KIMO}" --host http://remote.kimo-test.invalid:9 \
    launch kimi --provider ollama --model test-local >/dev/null 2>&1
check "remote Ollama clears DASHSCOPE_API_KEY" "<unset>" "$(env_val "${CAPTURE}" DASHSCOPE_API_KEY)"

echo "[*] [6] No Ollama probing on the hosted path"
cat > "${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DASHSCOPE_TEST_CAPTURE}.curl"
exit 7
SH
chmod +x "${FAKE_BIN}/curl"
( unset OLLAMA_REMOTE_URL; DASHSCOPE_API_KEY="${KEY}" "${KIMO}" --remote launch kimi --provider dashscope --dry-run >/dev/null )
check "dashscope routing never probes Ollama" no "$([[ -f "${CAPTURE}.curl" ]] && echo yes || echo no)"
rm -f "${FAKE_BIN}/curl"

echo
harness_summary "dashscope_smoke"
