#!/usr/bin/env bash
# Headless smoke tests for the ModelScope cloud provider
# ('launch --provider modelscope'): config-alias routing for kimi, live
# catalogue registration, credential handling and the env-channel fallback.
#
# Asserts:
#   * dry-run reports the ModelScope host, default model, context and masked
#     token; --ctx overrides the context window
#   * a missing token (or kimo's own 'ollama' placeholder) fails with a hint
#     pointing at modelscope.cn/my/myaccesstoken
#   * a --model may be the wire id, a modelscope/ alias, or an Ollama-style
#     tag - deepseek-v4.1-flash-1017 resolves to the served org-prefixed id
#   * a modelscope/<id> --model selects the provider without --provider
#   * unsupported CLIs are rejected
#   * a validated launch registers [providers.modelscope] (api_key_env, never
#     the token itself) plus one alias per served chat model, pins
#     default_model, and execs kimi -m modelscope/<id> with the env channel
#     unset - so kimi's picker shows 'modelscope', not '__kimi_env__'
#   * non-chat ids (embeddings) are filtered out of the registered catalogue
#   * a rejected token (401) aborts the launch
#   * an unreachable ModelScope host falls back to the KIMI_MODEL_* env
#     channel with a __kimi_env__ warning
#   * a modelscope/ default_model keeps --provider dashscope on the free tier
#     and _kimi_sync_model_context updates the modelscope/ alias in place
#     instead of synthesizing an alibaba/modelscope/... alias
#
# Usage: tests/modelscope-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# A developer shell may export a real token; the missing-key checks below must
# see an empty environment.
unset MODELSCOPE_API_KEY MODELSCOPE_TOKEN DASHSCOPE_API_KEY MODELSTUDIO_API_KEY
# Keep the token-resolution fallbacks away from this machine's real qwen /
# kimocoder settings files.
export KIMO_MODELSCOPE_SETTINGS="${HARNESS_ROOT}/no-such-settings.json"

FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/modelscope-call.txt"
mkdir -p "${FAKE_BIN}"
export MODELSCOPE_TEST_CAPTURE="${CAPTURE}"
cat > "${FAKE_BIN}/kimi" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in KIMI_MODEL_NAME KIMI_MODEL_API_KEY KIMI_MODEL_PROVIDER_TYPE KIMI_MODEL_BASE_URL \
        KIMI_MODEL_MAX_CONTEXT_SIZE KIMI_MODEL_CAPABILITIES KIMI_MODEL_REASONING_KEY \
        KIMI_MODEL_THINKING_EFFORT MODELSCOPE_API_KEY; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${MODELSCOPE_TEST_CAPTURE:?}"
printf '{"native":true}\n'
exit "${MODELSCOPE_TEST_RC:-0}"
SH
chmod +x "${FAKE_BIN}/kimi"
export PATH="${FAKE_BIN}:${PATH}"

MS_TOKEN="ms-fixture-modelscope-token"
KIMI_HOME_DIR="${HARNESS_ROOT}/kimi-home"
mkdir -p "${KIMI_HOME_DIR}"
: >"${CAPTURE}"

echo "[*] [1] Credential checks"

rc=0
nokey=$("${KIMO}" launch kimi --provider modelscope --dry-run 2>&1) || rc=$?
check "a missing token fails" 1 "${rc}"
check_contains "the missing-token error names the env var" "MODELSCOPE_API_KEY" "${nokey}"
check_contains "the missing-token error points at modelscope.cn" "myaccesstoken" "${nokey}"

rc=0
placeholder=$(MODELSCOPE_API_KEY=ollama "${KIMO}" launch kimi --provider modelscope --dry-run 2>&1) || rc=$?
check "the 'ollama' placeholder token fails" 1 "${rc}"
check_contains "the placeholder error names the env var" "MODELSCOPE_API_KEY" "${placeholder}"

rc=0
unsupported=$("${KIMO}" launch codex --provider modelscope --dry-run 2>&1) || rc=$?
check "an unsupported CLI fails" 1 "${rc}"
check_contains "the unsupported-CLI error names the provider" "modelscope" "${unsupported}"

echo
echo "[*] [2] Dry-run report"

MS_CONFIG="${HARNESS_ROOT}/empty/config.toml"
mkdir -p "$(dirname "${MS_CONFIG}")"
: >"${MS_CONFIG}"
dry=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${MS_CONFIG}" \
    "${KIMO}" launch kimi --provider modelscope --dry-run)
check_contains "dry-run names the provider" "provider: modelscope" "${dry}"
check_contains "dry-run names the host" "https://api-inference.modelscope.cn/v1" "${dry}"
check_contains "dry-run shows the preset default model" "model  : deepseek-ai/DeepSeek-V4.1-Flash-1017" "${dry}"
check_contains "dry-run argv uses the config alias" "kimi -m modelscope/deepseek-ai/DeepSeek-V4.1-Flash-1017" "${dry}"
check_contains "dry-run context is the ModelScope default" "context: 1000000 tokens" "${dry}"
check_contains "dry-run masks the token" "<kept: real value, ModelScope token>" "${dry}"
check_not_contains "dry-run never prints the token" "${MS_TOKEN}" "${dry}"

dry_ctx=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${MS_CONFIG}" \
    "${KIMO}" launch kimi --provider modelscope --ctx 12345 --dry-run)
check_contains "--ctx overrides the window" "context: 12345 tokens" "${dry_ctx}"

# A bare Ollama-style tag is accepted; the live catalogue resolves it to the
# org-prefixed id at launch time (a dry run does not contact the server).
dry_bare=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${MS_CONFIG}" \
    "${KIMO}" launch kimi --provider modelscope -m deepseek-v4.1-flash-1017 --dry-run)
check_contains "a bare tag keeps its modelscope/ alias" "kimi -m modelscope/deepseek-v4.1-flash-1017" "${dry_bare}"

dry_ns=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${MS_CONFIG}" \
    "${KIMO}" launch kimi --model modelscope/deepseek-ai/DeepSeek-V4.1-Flash-1017 --dry-run)
check_contains "a modelscope/ model selects the provider" "provider: modelscope" "${dry_ns}"

echo
echo "[*] [3] Live catalogue registration (config alias, not __kimi_env__)"

harness_fake_ollama --openai-models "deepseek-ai/DeepSeek-V4.1-Flash-1017,Qwen/Qwen3.8-Max,text-embedding-v4" \
    --openai-bearer "${MS_TOKEN}"
MS_UP_LOG="${FAKE_OLLAMA_LOG}"

LIVE_CONFIG="${HARNESS_ROOT}/live/config.toml"
mkdir -p "$(dirname "${LIVE_CONFIG}")"
: >"${LIVE_CONFIG}"
: >"${CAPTURE}"
MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${LIVE_CONFIG}" \
    KIMO_MODELSCOPE_BASE_URL="${FAKE_OLLAMA_URL}/v1" \
    "${KIMO}" launch kimi --provider modelscope --model deepseek-v4.1-flash-1017 >/dev/null 2>&1
check "the Ollama-style tag resolves to the served id" "modelscope/deepseek-ai/DeepSeek-V4.1-Flash-1017" "$(flag_val "${CAPTURE}" -m)"
check "the env channel stays unset behind the config alias" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "the token reaches kimi by env var" "${MS_TOKEN}" "$(env_val "${CAPTURE}" MODELSCOPE_API_KEY)"
cfg=$(cat "${LIVE_CONFIG}")
check_contains "the provider block is registered" "[providers.modelscope]" "${cfg}"
check_contains "the credential is an env-var reference" 'api_key_env = "MODELSCOPE_API_KEY"' "${cfg}"
check_not_contains "the token is never written to disk" "${MS_TOKEN}" "${cfg}"
check_contains "the fake host is recorded" "base_url = \"${FAKE_OLLAMA_URL}/v1\"" "${cfg}"
check_contains "the launched alias is registered" '[models."modelscope/deepseek-ai/DeepSeek-V4.1-Flash-1017"]' "${cfg}"
check_contains "the alias points at the provider" "provider = \"modelscope\"" "${cfg}"
check_contains "the launched alias is pinned as default" 'default_model = "modelscope/deepseek-ai/DeepSeek-V4.1-Flash-1017"' "${cfg}"
check_contains "the flash heuristic sets a 1M window" "max_context_size = 1000000" "${cfg}"
check_contains "a thinking model gets its capabilities" "thinking" "${cfg}"
check_contains "a second served model is registered" '[models."modelscope/Qwen/Qwen3.8-Max"]' "${cfg}"
check_not_contains "non-chat ids are filtered" "text-embedding-v4" "${cfg}"
check_contains "the catalogue was actually fetched" "GET /v1/models" "$(<"${MS_UP_LOG}")"

echo
echo "[*] [4] Rejected token aborts, unreachable host falls back"

harness_fake_ollama --openai-models "deepseek-ai/DeepSeek-V4.1-Flash-1017" \
    --openai-bearer "ms-fixture-other-token"
BAD_CONFIG="${HARNESS_ROOT}/bad/config.toml"
mkdir -p "$(dirname "${BAD_CONFIG}")"
: >"${BAD_CONFIG}"
rc=0
rejected=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${BAD_CONFIG}" \
    KIMO_MODELSCOPE_BASE_URL="${FAKE_OLLAMA_URL}/v1" \
    "${KIMO}" launch kimi --provider modelscope 2>&1) || rc=$?
check "a rejected token aborts the launch" 1 "${rc}"
check_contains "the rejection error names ModelScope" "ModelScope" "${rejected}"
check_contains "the rejection error names the endpoint" "/models" "${rejected}"
check_not_contains "the rejection error never prints the token" "${MS_TOKEN}" "${rejected}"

FALLBACK_CONFIG="${HARNESS_ROOT}/fallback/config.toml"
mkdir -p "$(dirname "${FALLBACK_CONFIG}")"
: >"${FALLBACK_CONFIG}"
: >"${CAPTURE}"
MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${FALLBACK_CONFIG}" \
    KIMO_MODELSCOPE_BASE_URL="http://127.0.0.1:9/v1" \
    "${KIMO}" launch kimi --provider modelscope >/dev/null 2>&1
check "an unreachable host falls back to the env channel" "deepseek-ai/DeepSeek-V4.1-Flash-1017" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
fb_warn=$(MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${FALLBACK_CONFIG}" \
    KIMO_MODELSCOPE_BASE_URL="http://127.0.0.1:9/v1" \
    "${KIMO}" launch kimi --provider modelscope 2>&1 >/dev/null) || true
check_contains "the fallback warns about __kimi_env__" "__kimi_env__" "${fb_warn}"

echo
echo "[*] [5] modelscope/ aliases and the dashscope free tier"

# A modelscope/ default_model must not steal --provider dashscope from the
# free-tier block, and a modelscope/ resolved alias updates its own entry
# (never a synthesized alibaba/modelscope/... one).
FT_CONFIG="${HARNESS_ROOT}/ft/config.toml"
mkdir -p "$(dirname "${FT_CONFIG}")"
cat > "${FT_CONFIG}" <<TOML
default_model = "modelscope/deepseek-ai/DeepSeek-V4-Flash-0731"
[providers.alibaba]
type = "openai"
base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
api_key = "sk-dashscope-fixture-ft"
[providers.modelscope]
type = "openai"
base_url = "https://api-inference.modelscope.cn/v1"
api_key = "sk-dashscope-not-a-modelscope-token"
[models."modelscope/deepseek-ai/DeepSeek-V4-Flash-0731"]
provider = "modelscope"
model = "deepseek-ai/DeepSeek-V4-Flash-0731"
max_context_size = 999
TOML
: >"${CAPTURE}"
KIMI_CONFIG="${FT_CONFIG}" "${KIMO}" launch kimi --provider dashscope >/dev/null 2>&1
check "the dashscope free tier launches the modelscope alias" "modelscope/deepseek-ai/DeepSeek-V4-Flash-0731" "$(flag_val "${CAPTURE}" -m)"
ft_cfg=$(cat "${FT_CONFIG}")
check_contains "the modelscope alias window is synced in place" "max_context_size = 500000" "${ft_cfg}"
check_not_contains "no alibaba/modelscope hybrid alias is created" 'alibaba/modelscope/' "${ft_cfg}"

echo
harness_summary "modelscope_smoke"
