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
#   * agy rides the Gemini shim in OpenAI mode: a real translated turn reaches
#     /chat/completions with the key as a bearer token, agy's own environment
#     never sees that key, and its settings are restored afterwards
#   * provider 'alibaba' routes to freetier-managed [providers.alibaba] with
#     500,000 context by default and syncs config.toml max_context_size
#   * 'launch claude --provider alibaba' uses that same block through the
#     localhost Messages proxy (chat/completions upstream). The stored key
#     is not exported to claude. Keyed '--provider dashscope' still has no
#     freetier fallback.
#
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
cat > "${FAKE_BIN}/claude" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL \
        ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
        CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${DASHSCOPE_TEST_CAPTURE:?}"
printf '{"native":true}\n'
exit 0
SH
chmod +x "${FAKE_BIN}/claude"
export PATH="${FAKE_BIN}:${PATH}"

KEY="sk-dashscope-fixture-12345"
SP_KEY="sk-sp-token-plan-fixture-67890"
HOST="https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
PLAN_HOST="https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"

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
plan=$(DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "a token-plan key selects the plan surface" "host   : ${PLAN_HOST}" "${plan}"
mixed=$(DASHSCOPE_API_KEY="${SP_KEY}" MODELSTUDIO_API_KEY="${KEY}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "the first set variable wins (plan)" "host   : ${PLAN_HOST}" "${mixed}"

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
DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch kimi --provider dashscope >/dev/null 2>&1
check "the token-plan key reaches kimi on the plan surface" "${SP_KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "kimi receives the plan base URL" "${PLAN_HOST}" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"

echo "[*] [5] Precedence, supported CLIs and scrubbing"
rc=0
unsupported=$("${KIMO}" launch grok --provider dashscope --dry-run 2>&1) || rc=$?
check "unsupported cloud CLI rejected" 1 "${rc}"
check_contains "the rejection names the supported CLIs" "claude kimi" "${unsupported}"
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

echo "[*] [7] Claude on the Model Studio surfaces"
DASHSCOPE_API_KEY="${KEY}" "${KIMO}" launch claude --provider dashscope >/dev/null 2>&1
check "claude gets the intl anthropic surface" "https://dashscope-intl.aliyuncs.com/apps/anthropic" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
check "claude gets the bearer token" "${KEY}" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"
check "claude's x-api-key is unset" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "claude defaults to the opus mapping on intl" "qwen3.8-max" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
check "haiku tier maps to qwen3.6-flash" "qwen3.6-flash" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
check "sonnet tier maps to qwen3.8-flash" "qwen3.8-flash" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
check "opus tier maps to qwen3.8-max" "qwen3.8-max" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
check "subagents stay on the surface" "auto" "$(env_val "${CAPTURE}" CLAUDE_CODE_SUBAGENT_MODEL)"
check "claude context is 983616" "983616" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch claude --provider dashscope -m qwen3.8-max >/dev/null 2>&1
check "claude gets the plan anthropic surface" "https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
check "explicit model reaches ANTHROPIC_MODEL" "qwen3.8-max" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch claude --provider dashscope >/dev/null 2>&1
check "claude defaults to auto on the plan surface" "auto" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
rc=0
nokey_claude=$("${KIMO}" launch claude --provider dashscope --dry-run 2>&1) || rc=$?
check "claude has no freetier fallback" 1 "${rc}"
check_contains "the fallback refusal names the env vars" "DASHSCOPE_API_KEY" "${nokey_claude}"

echo "[*] [8] Free-tier fallback via kimi's freetier block"
FT_CONFIG="${HARNESS_ROOT}/ft/config.toml"
mkdir -p "$(dirname "${FT_CONFIG}")"
cat > "${FT_CONFIG}" <<'TOML'
default_model = "alibaba/qwen3-coder-flash-2025-07-28"
[providers.alibaba]
type = "openai"
base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
api_key = "sk-ws-fixture-stored-key"
[models."alibaba/qwen3-coder-flash-2025-07-28"]
provider = "alibaba"
model = "qwen3-coder-flash-2025-07-28"
max_context_size = 131072
max_output_size = 32768
TOML
ft=$(KIMI_CONFIG="${FT_CONFIG}" "${KIMO}" launch kimi --provider dashscope --dry-run)
check_contains "fallback rides the freetier alias" "model  : alibaba/qwen3-coder-flash-2025-07-28" "${ft}"
check_contains "fallback notes kimi's own provider" "freetier-managed [providers.alibaba]" "${ft}"
KIMI_CONFIG="${FT_CONFIG}" "${KIMO}" launch kimi --provider dashscope >/dev/null 2>&1
check "fallback launches kimi with the alias" "alibaba/qwen3-coder-flash-2025-07-28" "$(flag_val "${CAPTURE}" -m)"
check "fallback exports no KIMI_MODEL key" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"

echo "[*] [9] agy: Gemini wire onto the compatible-mode surface"
# agy speaks only the Gemini protocol and Model Studio has no Gemini endpoint,
# so kimo must spawn the shim in its OpenAI-compatible mode. A loopback
# stand-in for the plan surface answers /chat/completions only for the right
# bearer token, which is what proves the key reached the shim and not agy.
harness_fake_ollama --openai-models qwen3.8-max --openai-bearer "${SP_KEY}" --openai-chat PONG
PLAN_URL="${FAKE_OLLAMA_URL}" PLAN_LOG="${FAKE_OLLAMA_LOG}"
harness_fake_ollama --openai-models qwen3-coder-plus --openai-bearer "${KEY}" --openai-chat PONG
INTL_URL="${FAKE_OLLAMA_URL}" INTL_LOG="${FAKE_OLLAMA_LOG}"
AGY_CAPTURE="${HARNESS_ROOT}/dashscope-agy.txt"
export AGY_SMOKE_CAPTURE="${AGY_CAPTURE}"
export AGY_SETTINGS="${HARNESS_ROOT}/agy-settings.json"
export KIMO_AGY_CLAIM_DIR="${HARNESS_ROOT}/agy-claims"
printf '{"model":"Old Model","trustedWorkspaces":["/x"]}' > "${AGY_SETTINGS}"

cat > "${FAKE_BIN}/agy" <<'SH'
#!/usr/bin/env bash
out="${AGY_SMOKE_CAPTURE:?}"
argv=("$@")
model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) model="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
base="${GOOGLE_GEMINI_BASE_URL-}"
answer=""
if [[ -n "${base}" ]]; then
    # A real Gemini-wire turn through the shim, the way agy itself would send it.
    answer="$(curl -s -m 20 -X POST "${base}/v1beta/models/${model}:generateContent" \
        -H 'Content-Type: application/json' -H "x-goog-api-key: ${GEMINI_API_KEY-}" \
        -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}' 2>/dev/null || true)"
fi
{
    printf 'ARGV\n'
    printf '%s\n' "${argv[@]}"
    printf 'ENV\n'
    for key in GOOGLE_GEMINI_BASE_URL GEMINI_API_KEY DASHSCOPE_API_KEY MODELSTUDIO_API_KEY \
        KIMO_SHIM_UPSTREAM_TOKEN OLLAMA_HOST OPENAI_BASE_URL OPENAI_API_KEY; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
    printf 'ANSWER=%s\n' "${answer}"
} > "${out}"
exit 0
SH
chmod +x "${FAKE_BIN}/agy"

KIMO_DASHSCOPE_PLAN_BASE_URL="${PLAN_URL}/plan" DASHSCOPE_API_KEY="${SP_KEY}" \
    "${KIMO}" launch agy --provider dashscope >/dev/null 2>&1
check "agy is launched with the DashScope default model" "qwen3.8-max" "$(flag_val "${AGY_CAPTURE}" --model)"
check_match "agy points at a loopback shim" '^http://127\.0\.0\.1:[0-9]+$' "$(env_val "${AGY_CAPTURE}" GOOGLE_GEMINI_BASE_URL)"
check_contains "the shim translated a real turn end to end" "PONG" "$(env_val "${AGY_CAPTURE}" ANSWER)"
check_contains "the shim posted chat/completions on the plan surface" \
    "POST /plan/compatible-mode/v1/chat/completions" "$(<"${PLAN_LOG}")"
check "agy never receives DASHSCOPE_API_KEY" "<unset>" "$(env_val "${AGY_CAPTURE}" DASHSCOPE_API_KEY)"
check "agy never receives MODELSTUDIO_API_KEY" "<unset>" "$(env_val "${AGY_CAPTURE}" MODELSTUDIO_API_KEY)"
check "agy never receives the shim's upstream token" "<unset>" "$(env_val "${AGY_CAPTURE}" KIMO_SHIM_UPSTREAM_TOKEN)"
check "no Ollama host is exported" "<unset>" "$(env_val "${AGY_CAPTURE}" OLLAMA_HOST)"
want="$(printf '%s' '{"model":"Old Model","trustedWorkspaces":["/x"]}' | jq -cS .)"
got="$(jq -cS . "${AGY_SETTINGS}" 2>/dev/null || true)"
check "agy settings are restored after the session" "${want}" "${got}"

# An explicit model and the intl surface both reach the same wire. Note the two
# overrides differ in shape: KIMO_DASHSCOPE_PLAN_BASE_URL is an origin that kimo
# appends /compatible-mode/v1 to, KIMO_DASHSCOPE_BASE_URL is the whole base.
KIMO_DASHSCOPE_BASE_URL="${INTL_URL}/intl/compatible-mode/v1" MODELSTUDIO_API_KEY="${KEY}" \
    "${KIMO}" launch agy --provider dashscope --model qwen3-coder-plus >/dev/null 2>&1
check "an explicit model reaches agy" "qwen3-coder-plus" "$(flag_val "${AGY_CAPTURE}" --model)"
check_contains "the intl key rides the intl surface" \
    "POST /intl/compatible-mode/v1/chat/completions" "$(<"${INTL_LOG}")"
check_contains "the translated turn still answers" "PONG" "$(env_val "${AGY_CAPTURE}" ANSWER)"

# The shim is per-session: nothing is left listening once kimo exits.
port="$(env_val "${AGY_CAPTURE}" GOOGLE_GEMINI_BASE_URL)"
if curl -sf -m 2 "${port}/healthz" >/dev/null 2>&1; then
    bad "shim still listening on ${port} after kimo exit"
else
    ok "shim stopped after kimo exit"
fi
rm -f "${FAKE_BIN}/agy"
unset AGY_SMOKE_CAPTURE AGY_SETTINGS KIMO_AGY_CLAIM_DIR

echo "[*] [10] Provider 'alibaba' explicit routing and 500,000 context"
ALI_CONFIG="${HARNESS_ROOT}/ali/config.toml"
mkdir -p "$(dirname "${ALI_CONFIG}")"
cat > "${ALI_CONFIG}" <<'TOML'
default_model = "alibaba/deepseek-v4.1-flash-1017"
[providers.alibaba]
type = "openai"
base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
api_key = "sk-ws-fixture-stored-key"
[models."alibaba/deepseek-v4.1-flash-1017"]
provider = "alibaba"
model = "deepseek-v4.1-flash-1017"
max_context_size = 131072
max_output_size = 32768
[models."alibaba/qwen3-coder-flash-2025-07-28"]
provider = "alibaba"
model = "qwen3-coder-flash-2025-07-28"
max_context_size = 131072
max_output_size = 32768
TOML

dry_ali=$(KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --provider alibaba --dry-run)
check_contains "provider reported as alibaba" "provider: alibaba" "${dry_ali}"
check_contains "default model is deepseek" "model  : alibaba/deepseek-v4.1-flash-1017" "${dry_ali}"
check_contains "default context is 500000 tokens" "context: 500000 tokens" "${dry_ali}"
check_contains "argv launches kimi with deepseek alias" "argv   : kimi -m alibaba/deepseek-v4.1-flash-1017" "${dry_ali}"

dry_ali_ctx=$(KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --provider alibaba --ctx 12345 --dry-run)
check_contains "--ctx overrides alibaba context" "context: 12345 tokens" "${dry_ali_ctx}"

dry_ali_model=$(KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --provider alibaba -m alibaba/qwen3-coder-flash-2025-07-28 --dry-run)
check_contains "explicit model alias is preserved" "model  : alibaba/qwen3-coder-flash-2025-07-28" "${dry_ali_model}"
check_contains "model alias keeps 500000 context default" "context: 500000 tokens" "${dry_ali_model}"

dry_ali_bare=$(KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --provider alibaba -m deepseek-v4.1-flash-1017 --dry-run)
check_contains "bare model name is auto-prefixed with alibaba/" "model  : alibaba/deepseek-v4.1-flash-1017" "${dry_ali_bare}"

KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --provider alibaba >/dev/null 2>&1
check "live alibaba launch launches kimi with deepseek alias" "alibaba/deepseek-v4.1-flash-1017" "$(flag_val "${CAPTURE}" -m)"
check "live alibaba launch sets KIMI_MODEL_MAX_CONTEXT_SIZE" "500000" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check "live alibaba launch leaves KIMI_MODEL_NAME unset" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "live alibaba launch leaves KIMI_MODEL_API_KEY unset" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
got_ctx="$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${ALI_CONFIG}').read()); print(doc.get('models', {}).get('alibaba/deepseek-v4.1-flash-1017', {}).get('max_context_size', ''))" 2>/dev/null || true)"
check "live alibaba launch synced max_context_size in config.toml" "500000" "${got_ctx}"

"${KIMO}" config set cloud_provider alibaba >/dev/null
check "config accepts alibaba" "alibaba" "$("${KIMO}" config get cloud_provider)"
dry_cfg=$(KIMI_CONFIG="${ALI_CONFIG}" "${KIMO}" launch kimi --dry-run)
check_contains "configured backend alibaba is used" "provider: alibaba" "${dry_cfg}"
"${KIMO}" config unset cloud_provider >/dev/null

echo "[*] [11] Claude on the free-tier block (same models as kimi)"
# The upstream is a loopback OpenAI fixture. Nothing in this section may
# call the real Model Studio host.
ALI_KEY="sk-ws-fixture-claude-ali"
harness_fake_ollama --openai-models deepseek-v4.1-flash-1017,qwen3-coder-flash-2025-07-28,real-wire-id \
    --openai-bearer "${ALI_KEY}" --openai-chat PONG
ALI_UP_LOG="${FAKE_OLLAMA_LOG}"
CLAUDE_ALI_CONFIG="${HARNESS_ROOT}/ali-claude/config.toml"
mkdir -p "$(dirname "${CLAUDE_ALI_CONFIG}")"
cat > "${CLAUDE_ALI_CONFIG}" <<TOML
default_model = "alibaba/deepseek-v4.1-flash-1017"
[providers.alibaba]
type = "openai"
base_url = "${FAKE_OLLAMA_URL}/v1"
api_key = "${ALI_KEY}"
[models."alibaba/deepseek-v4.1-flash-1017"]
provider = "alibaba"
model = "deepseek-v4.1-flash-1017"
max_context_size = 131072
max_output_size = 32768
[models."alibaba/qwen3-coder-flash-2025-07-28"]
provider = "alibaba"
model = "qwen3-coder-flash-2025-07-28"
max_context_size = 131072
max_output_size = 32768
[models."alibaba/alias-only"]
provider = "alibaba"
model = "real-wire-id"
max_context_size = 131072
max_output_size = 32768
TOML

rc=0
missing=$("${KIMO}" launch claude --provider alibaba --dry-run 2>&1) || rc=$?
check "claude alibaba without a freetier block fails" 1 "${rc}"
check_contains "the missing-block error names the free-tier model" "free-tier model" "${missing}"

NOKEY_CONFIG="${HARNESS_ROOT}/ali-nokey/config.toml"
mkdir -p "$(dirname "${NOKEY_CONFIG}")"
cat > "${NOKEY_CONFIG}" <<'TOML'
default_model = "alibaba/deepseek-v4.1-flash-1017"
[providers.alibaba]
type = "openai"
base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
[models."alibaba/deepseek-v4.1-flash-1017"]
provider = "alibaba"
model = "deepseek-v4.1-flash-1017"
max_context_size = 131072
TOML
rc=0
nokey_ali=$(KIMI_CONFIG="${NOKEY_CONFIG}" "${KIMO}" launch claude --provider alibaba --dry-run 2>&1) || rc=$?
check "claude alibaba without a stored credential fails" 1 "${rc}"
check_contains "the missing-credential error names providers.alibaba" "[providers.alibaba]" "${nokey_ali}"

dry_claude=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba --dry-run)
check_contains "claude alibaba provider is alibaba" "provider: alibaba" "${dry_claude}"
check_contains "claude alibaba default wire id is the bare slug" "model  : deepseek-v4.1-flash-1017" "${dry_claude}"
check_contains "claude alibaba context is 500000" "context: 500000 tokens" "${dry_claude}"
check_contains "claude alibaba wire is the messages proxy" "wire   : anthropic -> chat (${FAKE_OLLAMA_URL}/v1)" "${dry_claude}"
check_contains "claude alibaba argv passes the bare slug" "argv   : claude --model deepseek-v4.1-flash-1017" "${dry_claude}"
check_contains "claude alibaba note keeps the key out of claude" "not exported to claude" "${dry_claude}"
check_not_contains "dry-run does not print the stored key" "${ALI_KEY}" "${dry_claude}"

dry_ctx=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba --ctx 12345 --dry-run)
check_contains "--ctx overrides claude alibaba context" "context: 12345 tokens" "${dry_ctx}"

dry_explicit=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba -m alibaba/qwen3-coder-flash-2025-07-28 --dry-run)
check_contains "explicit alibaba alias becomes the wire id" "model  : qwen3-coder-flash-2025-07-28" "${dry_explicit}"

dry_bare=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba -m deepseek-v4.1-flash-1017 --dry-run)
check_contains "bare model name stays the wire id" "model  : deepseek-v4.1-flash-1017" "${dry_bare}"

dry_field=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba -m alibaba/alias-only --dry-run)
check_contains "the config model field is the wire id" "model  : real-wire-id" "${dry_field}"

dry_hijack=$(DASHSCOPE_API_KEY="sk-hijack-not-freetier" KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" \
    "${KIMO}" launch claude --provider alibaba --dry-run)
check_contains "an env key does not switch alibaba onto the opus tier" "model  : deepseek-v4.1-flash-1017" "${dry_hijack}"
check_not_contains "an env key does not switch alibaba onto apps/anthropic" "apps/anthropic" "${dry_hijack}"
check_contains "an env key still uses the free-tier chat proxy" "wire   : anthropic -> chat (${FAKE_OLLAMA_URL}/v1)" "${dry_hijack}"
check_not_contains "dry-run masks the unused env key" "sk-hijack-not-freetier" "${dry_hijack}"

cat > "${FAKE_BIN}/claude" <<'SH'
#!/usr/bin/env bash
out="${DASHSCOPE_TEST_CAPTURE:?}"
argv=("$@")
model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) model="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
answer=""
answer_opus=""
model_meta=""
base="${ANTHROPIC_BASE_URL-}"
token="${ANTHROPIC_AUTH_TOKEN-}"
if [[ -n "${base}" && -n "${token}" && -n "${model}" ]]; then
    ns=$(jq -nc --arg m "alibaba/${model}" '{model:$m,max_tokens:16,stream:false,messages:[{role:"user",content:"hi"}]}')
    op=$(jq -nc '{model:"opus",max_tokens:16,stream:false,messages:[{role:"user",content:"hi"}]}')
    codex_body=$(jq -nc '{model:"gpt-6.1-sol",max_tokens:16,stream:false,messages:[{role:"user",content:"hi"}]}')
    answer="$(curl -sS -m 20 -X POST "${base}/v1/messages" \
        -H 'Content-Type: application/json' -H "x-api-key: ${token}" -d "${ns}" || true)"
    answer_opus="$(curl -sS -m 20 -X POST "${base}/v1/messages" \
        -H 'Content-Type: application/json' -H "x-api-key: ${token}" -d "${op}" || true)"
    curl -sS -m 20 -X POST "${base}/v1/messages" \
        -H 'Content-Type: application/json' -H "x-api-key: ${token}" -d "${codex_body}" >/dev/null || true
    model_meta="$(curl -sS -m 20 "${base}/v1/models/${model}" -H "x-api-key: ${token}" || true)"
fi
{
    printf 'ARGV\n'
    printf '%s\n' "${argv[@]}"
    printf 'ENV\n'
    for key in ANTHROPIC_BASE_URL ANTHROPIC_API_BASE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL \
        ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
        ANTHROPIC_DEFAULT_FABLE_MODEL CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_MAX_CONTEXT_TOKENS \
        KIMO_ALIBABA_API_KEY KIMO_CLAUDE_CATALOG_CTX DASHSCOPE_API_KEY MODELSTUDIO_API_KEY; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
    printf 'ANSWER=%s\n' "${answer}"
    printf 'ANSWER_OPUS=%s\n' "${answer_opus}"
    printf 'MODEL_META=%s\n' "${model_meta}"
} > "${out}"
exit 0
SH
chmod +x "${FAKE_BIN}/claude"

mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" << 'EOF'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(echo ok)"]},
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gpt-6.1-sol",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gpt-6.1-sol",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gpt-6.1-sol",
    "CLAUDE_CODE_SUBAGENT_MODEL": "gpt-6.1-sol",
    "KEEP_ME": "yes"
  }
}
EOF
: >"${ALI_UP_LOG}"
KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --provider alibaba >/dev/null 2>&1
check "live claude alibaba argv is the bare slug" "deepseek-v4.1-flash-1017" "$(flag_val "${CAPTURE}" --model)"
check "live claude alibaba sets ANTHROPIC_MODEL" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
check_match "live claude points at the loopback proxy" '^http://127\.0\.0\.1:[0-9]+$' "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
check "live claude proxy is not the upstream itself" "different" \
    "$([[ "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)" == "${FAKE_OLLAMA_URL}" ]] && echo same || echo different)"
check "live claude context is 500000" "500000" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
check "haiku pin is the launched slug" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
check "sonnet pin is the launched slug" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
check "opus pin is the launched slug" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
check "fable pin is the launched slug" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_FABLE_MODEL)"
check "subagents use the launched slug" "deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" CLAUDE_CODE_SUBAGENT_MODEL)"
check "claude alibaba leaves x-api-key unset" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "the inline key is not exported to claude" "<unset>" "$(env_val "${CAPTURE}" KIMO_ALIBABA_API_KEY)"
check "catalog ctx knob is not exported to claude" "<unset>" "$(env_val "${CAPTURE}" KIMO_CLAUDE_CATALOG_CTX)"
check "DASHSCOPE_API_KEY is not given to claude" "<unset>" "$(env_val "${CAPTURE}" DASHSCOPE_API_KEY)"
client_token="$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"
check "claude's bearer is not the stored key" "no" "$([[ "${client_token}" == "${ALI_KEY}" || -z "${client_token}" ]] && echo yes || echo no)"
check_not_contains "the capture never contains the stored key" "${ALI_KEY}" "$(<"${CAPTURE}")"
check_contains "a namespaced id is answered" "PONG" "$(env_val "${CAPTURE}" ANSWER)"
check_contains "the namespaced response echoes the id claude sent" "alibaba/deepseek-v4.1-flash-1017" "$(env_val "${CAPTURE}" ANSWER)"
check_contains "an opus alias is answered on the free-tier model" "PONG" "$(env_val "${CAPTURE}" ANSWER_OPUS)"
check_contains "model metadata reports the free-tier window" '"context_window": 500000' "$(env_val "${CAPTURE}" MODEL_META)"
check_contains "upstream saw chat/completions" "POST /v1/chat/completions" "$(<"${ALI_UP_LOG}")"
check_contains "upstream was asked for the bare slug" '"model":"deepseek-v4.1-flash-1017"' "$(<"${ALI_UP_LOG}")"
check_not_contains "upstream was not asked for opus" '"model":"opus"' "$(<"${ALI_UP_LOG}")"
check_not_contains "upstream was not asked for a Codex subagent slug" '"model":"gpt-6.1-sol"' "$(<"${ALI_UP_LOG}")"
check_not_contains "upstream was not asked for the alibaba/ alias" '"model":"alibaba/deepseek-v4.1-flash-1017"' "$(<"${ALI_UP_LOG}")"
check "settings keep the user's model choice" "opus" "$(python3 -c 'import json; print(json.load(open("'"${HOME}"'/.claude/settings.json"))["model"])')"
check "settings keep unrelated env" "yes" "$(python3 -c 'import json; print(json.load(open("'"${HOME}"'/.claude/settings.json"))["env"]["KEEP_ME"])')"
check "settings drop the Codex subagent pin" "absent" "$(python3 -c 'import json; env=json.load(open("'"${HOME}"'/.claude/settings.json")).get("env", {}); print("absent" if "CLAUDE_CODE_SUBAGENT_MODEL" not in env else env["CLAUDE_CODE_SUBAGENT_MODEL"])')"
check "settings drop the Codex opus pin" "absent" "$(python3 -c 'import json; env=json.load(open("'"${HOME}"'/.claude/settings.json")).get("env", {}); print("absent" if "ANTHROPIC_DEFAULT_OPUS_MODEL" not in env else env["ANTHROPIC_DEFAULT_OPUS_MODEL"])')"
got_ctx="$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${CLAUDE_ALI_CONFIG}').read()); print(doc.get('models', {}).get('alibaba/deepseek-v4.1-flash-1017', {}).get('max_context_size', ''))")"
check "claude launch does not rewrite kimi max_context_size" "131072" "${got_ctx}"
got_key="$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${CLAUDE_ALI_CONFIG}').read()); print(doc.get('providers', {}).get('alibaba', {}).get('api_key', ''))")"
check "claude launch does not rewrite the stored key" "${ALI_KEY}" "${got_key}"
picker="$(python3 -c 'import json; print(json.load(open("'"${HOME}"'/.claude/settings.json")).get("modelPicker", ""))')"
check "alibaba launch does not install a Codex model picker" "" "${picker}"
proxy_base="$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
proxy_dead=0
for _try in 1 2 3 4 5 6 7 8 9 10; do
    if ! curl -sS -m 1 -o /dev/null "${proxy_base}/v1/models" >/dev/null 2>&1; then
        proxy_dead=1
        break
    fi
    sleep 0.3
done
check "messages proxy stopped after claude exited" 1 "${proxy_dead}"

ENV_CONFIG="${HARNESS_ROOT}/ali-envkey/config.toml"
mkdir -p "$(dirname "${ENV_CONFIG}")"
cat > "${ENV_CONFIG}" <<TOML
default_model = "alibaba/qwen3-coder-flash-2025-07-28"
[providers.alibaba]
type = "openai"
base_url = "${FAKE_OLLAMA_URL}/v1"
api_key_env = "DASHSCOPE_API_KEY"
[models."alibaba/qwen3-coder-flash-2025-07-28"]
provider = "alibaba"
model = "qwen3-coder-flash-2025-07-28"
max_context_size = 131072
TOML
: >"${ALI_UP_LOG}"
DASHSCOPE_API_KEY="${ALI_KEY}" KIMI_CONFIG="${ENV_CONFIG}" "${KIMO}" launch claude --provider alibaba >/dev/null 2>&1
check "api_key_env launch uses the model field" "qwen3-coder-flash-2025-07-28" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
check "api_key_env is not left in claude's environment" "<unset>" "$(env_val "${CAPTURE}" DASHSCOPE_API_KEY)"
check_contains "api_key_env still reaches the upstream" '"model":"qwen3-coder-flash-2025-07-28"' "$(<"${ALI_UP_LOG}")"
check_contains "api_key_env turn is answered" "PONG" "$(env_val "${CAPTURE}" ANSWER)"
unset DASHSCOPE_API_KEY

rc=0
empty_env=$(KIMI_CONFIG="${ENV_CONFIG}" "${KIMO}" launch claude --provider alibaba --dry-run 2>&1) || rc=$?
check "an empty api_key_env fails" 1 "${rc}"
check_contains "the empty api_key_env error names the variable" "DASHSCOPE_API_KEY" "${empty_env}"

"${KIMO}" config set cloud_provider alibaba >/dev/null
dry_cfg_claude=$(KIMI_CONFIG="${CLAUDE_ALI_CONFIG}" "${KIMO}" launch claude --dry-run)
check_contains "configured backend alibaba launches claude on the free tier" "provider: alibaba" "${dry_cfg_claude}"
check_contains "configured backend keeps the bare slug" "model  : deepseek-v4.1-flash-1017" "${dry_cfg_claude}"
"${KIMO}" config unset cloud_provider >/dev/null

# A modelscope/ default_model must not steal --provider alibaba from the
# free-tier block freetier just wrote.
MS_CONFIG="${HARNESS_ROOT}/ali-ms/config.toml"
mkdir -p "$(dirname "${MS_CONFIG}")"
cat > "${MS_CONFIG}" <<TOML
default_model = "modelscope/deepseek-ai/DeepSeek-V4-Flash-0731"
[providers.alibaba]
type = "openai"
base_url = "${FAKE_OLLAMA_URL}/v1"
api_key = "${ALI_KEY}"
[providers.modelscope]
type = "openai"
base_url = "https://api-inference.modelscope.cn/v1"
api_key = "sk-dashscope-not-a-modelscope-token"
[models."modelscope/deepseek-ai/DeepSeek-V4-Flash-0731"]
provider = "modelscope"
model = "deepseek-ai/DeepSeek-V4-Flash-0731"
max_context_size = 131072
[models."alibaba/qwen3-coder-flash-2025-07-28"]
provider = "alibaba"
model = "qwen3-coder-flash-2025-07-28"
max_context_size = 131072
TOML
dry_ms=$(KIMI_CONFIG="${MS_CONFIG}" "${KIMO}" launch claude --provider alibaba --dry-run)
check_contains "alibaba launch ignores a modelscope default" "model  : qwen3-coder-flash-2025-07-28" "${dry_ms}"
check_contains "alibaba launch stays on the free-tier host" "wire   : anthropic -> chat (${FAKE_OLLAMA_URL}/v1)" "${dry_ms}"
check_not_contains "alibaba launch does not target ModelScope" "api-inference.modelscope.cn" "${dry_ms}"

# The model freetier wrote can itself be a ModelScope id. A DashScope sk-
# key on that host is the 401 "valid ModelScope token is supplied".
MS_ONLY="${HARNESS_ROOT}/ms-only/config.toml"
mkdir -p "$(dirname "${MS_ONLY}")"
cat > "${MS_ONLY}" <<'TOML'
default_model = "alibaba/deepseek-ai/DeepSeek-V4-Flash-0731"
[providers.alibaba]
type = "openai"
base_url = "https://api-inference.modelscope.cn/v1"
api_key = "sk-dashscope-not-a-modelscope-token"
[models."alibaba/deepseek-ai/DeepSeek-V4-Flash-0731"]
provider = "alibaba"
model = "deepseek-ai/DeepSeek-V4-Flash-0731"
max_context_size = 131072
TOML
rc=0
ms_need=$(KIMI_CONFIG="${MS_ONLY}" "${KIMO}" launch claude --provider alibaba --dry-run 2>&1) || rc=$?
check "ModelScope host without a token fails" 1 "${rc}"
check_contains "the error names ModelScope" "ModelScope" "${ms_need}"
check_contains "the error tells where the token comes from" "myaccesstoken" "${ms_need}"
check_not_contains "the error does not print the dashscope key" "sk-dashscope-not-a-modelscope-token" "${ms_need}"

MS_TOKEN="ms-fixture-modelscope-token"
harness_fake_ollama --openai-chat PONG --openai-bearer "${MS_TOKEN}"
MS_LOG="${FAKE_OLLAMA_LOG}"
cat > "${MS_ONLY}" <<TOML
default_model = "alibaba/deepseek-ai/DeepSeek-V4-Flash-0731"
[providers.modelscope]
type = "openai"
base_url = "${FAKE_OLLAMA_URL}/v1"
api_key = "sk-dashscope-not-a-modelscope-token"
[models."alibaba/deepseek-ai/DeepSeek-V4-Flash-0731"]
provider = "modelscope"
model = "deepseek-ai/DeepSeek-V4-Flash-0731"
max_context_size = 131072
TOML
: >"${MS_LOG}"
MODELSCOPE_API_KEY="${MS_TOKEN}" KIMI_CONFIG="${MS_ONLY}" "${KIMO}" launch claude --provider alibaba >/dev/null 2>&1
check "ModelScope wire id keeps the org slash" "deepseek-ai/DeepSeek-V4-Flash-0731" "$(flag_val "${CAPTURE}" --model)"
check_contains "ModelScope turn is answered with the access token" "PONG" "$(env_val "${CAPTURE}" ANSWER)"
check_contains "upstream was asked for the slashed ModelScope id" '"model":"deepseek-ai/DeepSeek-V4-Flash-0731"' "$(<"${MS_LOG}")"
check_not_contains "claude does not see the ModelScope token" "${MS_TOKEN}" "$(<"${CAPTURE}")"
check_not_contains "claude does not see the rejected DashScope key" "sk-dashscope-not-a-modelscope-token" "$(<"${CAPTURE}")"
unset MODELSCOPE_API_KEY

echo
harness_summary "dashscope_smoke"
