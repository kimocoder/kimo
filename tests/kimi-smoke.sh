#!/usr/bin/env bash
# Headless smoke tests for kimo's Kalidroid-backed 'kimi' launch branch.
#
# Usage: tests/kimi-smoke.sh [--live]

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
CURL_LOG="${TMPDIR_A}/curl.txt"
export KIMI_SMOKE_OUT="${CAPTURE}"
export KD_CURL_LOG="${CURL_LOG}"
export KIMI_CODE_HOME="${TMPDIR_A}/kimi-code"
mkdir -p "${KIMI_CODE_HOME}"

unset KALIDROID_API_KEY
KD_KEY="kd_ai_fixture-kimi-smoke"
KD_BASE="https://dashboard.kalidroid.com/api/ai/openai/v1"
QW_KEY="sk-qwencloud-fixture-kimi"
QW_BASE="https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1"

cat > "${FAKE_DIR}/kimi" <<'FAKE'
#!/usr/bin/env bash
out="${KIMI_SMOKE_OUT:?KIMI_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in KIMI_CODE_HOME KIMI_DISABLE_TELEMETRY KIMI_CODE_NO_AUTO_UPDATE \
        KIMI_MODEL_NAME KIMI_MODEL_PROVIDER_TYPE KIMI_MODEL_BASE_URL KIMI_MODEL_API_KEY \
        KIMI_MODEL_MAX_CONTEXT_SIZE KIMI_MODEL_CAPABILITIES KIMI_MODEL_REASONING_KEY \
        KIMI_MODEL_THINKING_EFFORT KIMI_MODEL_MAX_OUTPUT_SIZE KIMI_MODEL_DISPLAY_NAME \
        KALIDROID_API_KEY QWENCLOUD_API_KEY DASHSCOPE_API_KEY OLLAMA_HOST; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${out}"
exit 0
FAKE

cat > "${FAKE_DIR}/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -K) cat "$2" >> "${KD_CURL_LOG:?}"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w|-m|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf 'URL %s\n' "${url}" >> "${KD_CURL_LOG}"
status="${KD_FAKE_STATUS:-200}"
if [[ "${status}" == "000" ]]; then
    exit 7
fi
if [[ -n "${out}" ]]; then
    if [[ "${status}" == "200" ]]; then
        if [[ "${url}" == *qwencloudapi.com* ]]; then
            cat > "${out}" <<'JSON'
{"data":[
  {"id":"qwen4-max-preview"},
  {"id":"qwen3.8-max"},
  {"id":"deepseek-v4.1-flash"},
  {"id":"qwen-audio-3.0-asr-flash"},
  {"id":"qwen-image-3.0-pro"},
  {"id":"wan3.0-video"}
]}
JSON
        else
            cat > "${out}" <<'JSON'
{"data":[
  {"id":"qwen3.8-27b-uncensored","context_window":131072},
  {"id":"kimi-k3.1-pro","context_window":262144},
  {"id":"text-embedding-v4"}
]}
JSON
        fi
    else
        printf '{"error":"unauthorized"}\n' > "${out}"
    fi
fi
printf '%s' "${status}"
FAKE
chmod +x "${FAKE_DIR}/kimi" "${FAKE_DIR}/curl"
export PATH="${FAKE_DIR}:${PATH}"

echo "[*] Kimi defaults to Kalidroid"
rm -f "${CURL_LOG}"
dry=$(KALIDROID_API_KEY="${KD_KEY}" "${KIMO}" launch kimi --dry-run)
check "default Kalidroid launch does not probe Ollama" "no" "$([[ -f "${CURL_LOG}" ]] && grep -q '/api/tags' "${CURL_LOG}" && echo yes || echo no)"
check_contains "default provider is Kalidroid" "provider: kalidroid" "${dry}"
check_contains "default host is Kalidroid" "host   : ${KD_BASE}" "${dry}"
check_contains "default model is Kalidroid's preset" "model  : qwen3.8-27b" "${dry}"
check_contains "default argv uses a Kalidroid alias" "kimi -m kalidroid/qwen3.8-27b" "${dry}"
check_contains "dry-run masks the Kalidroid token" "KALIDROID_API_KEY <kept: real value, Kalidroid key>" "${dry}"
check_not_contains "dry-run never prints the Kalidroid token" "${KD_KEY}" "${dry}"
check_not_contains "Kalidroid does not set OLLAMA_HOST" "OLLAMA_HOST=" "${dry}"

dry=$(KALIDROID_API_KEY="${KD_KEY}" "${KIMO}" launch kimi --model kalidroid/kimi-k3 --ctx 262144 --dry-run)
check_contains "kalidroid/ prefix is stripped" "model  : kimi-k3" "${dry}"
check_contains "explicit model uses a Kalidroid alias" "kimi -m kalidroid/kimi-k3" "${dry}"
check_contains "--ctx overrides the Kalidroid window" "context: 262144 tokens" "${dry}"

rc=0
nokey=$("${KIMO}" launch kimi --dry-run 2>&1) || rc=$?
check "default Kimi launch needs a Kalidroid token" 1 "${rc}"
check_contains "missing-token error names KALIDROID_API_KEY" "KALIDROID_API_KEY" "${nokey}"

echo "[*] Kimi rejects removed Ollama and vLLM backends"
for removed in ollama none vllm; do
    rc=0
    rejected=$("${KIMO}" launch kimi --provider "${removed}" --dry-run 2>&1) || rc=$?
    check "Kimi rejects --provider ${removed}" 1 "${rc}"
    check_contains "${removed} rejection points to Kalidroid" "kalidroid" "${rejected}"
done
rc=0
rejected=$("${KIMO}" launch kimi --model vllm/org/model --dry-run 2>&1) || rc=$?
check "Kimi rejects a vllm/ model alias" 1 "${rc}"
check_contains "vllm/ rejection points to Kalidroid" "kalidroid" "${rejected}"

rc=0
cloud=$(OLLAMA_API_KEY=oc_fixture "${KIMO}" launch kimi --provider ollama-cloud --dry-run 2>&1) || rc=$?
check "Ollama Cloud remains supported" 0 "${rc}"
check_contains "Ollama Cloud provider is unchanged" "provider: ollama-cloud" "${cloud}"

echo "[*] Qwen alias launches Kimi with QwenCloud's validated catalogue"
dry=$(DASHSCOPE_API_KEY="${QW_KEY}" "${KIMO}" launch kimi --provider qwen --model qwen4-max-preview --dry-run)
check_contains "qwen is a QwenCloud provider alias" "provider: qwencloud" "${dry}"
check_contains "qwen alias uses the QwenCloud host" "host   : ${QW_BASE}" "${dry}"
check_contains "qwen alias keeps the requested model" "model  : qwen4-max-preview" "${dry}"
check_contains "qwen alias dry-run uses a canonical alias" "kimi -m qwencloud/qwen4-max-preview" "${dry}"
check_not_contains "qwen alias dry-run never prints the key" "${QW_KEY}" "${dry}"

QWEN_CONFIG="${TMPDIR_A}/qwen/config.toml"
mkdir -p "$(dirname "${QWEN_CONFIG}")"
printf 'default_model = "unrelated/model"\n\n[providers.unrelated]\ntype = "openai"\nbase_url = "https://unrelated.invalid/v1"\n' > "${QWEN_CONFIG}"
rm -f "${CAPTURE}" "${CURL_LOG}"
KIMI_CONFIG="${QWEN_CONFIG}" DASHSCOPE_API_KEY="${QW_KEY}" \
    "${KIMO}" launch kimi --provider qwen --model qwen4-max-preview >/dev/null 2>&1
check "qwen alias live launch execs kimi" "0" "$?"
check "qwen alias launches the canonical model alias" "yes" "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
check_contains "qwen alias argv selects qwen4-max-preview" "qwencloud/qwen4-max-preview" "$(cat "${CAPTURE}")"
check "qwen catalog request used the bearer credential" "yes" "$(grep -q "Authorization: Bearer ${QW_KEY}" "${CURL_LOG}" && echo yes || echo no)"
qw_cfg=$(cat "${QWEN_CONFIG}")
check_contains "QwenCloud provider is registered" "[providers.qwencloud]" "${qw_cfg}"
check_contains "QwenCloud base URL is registered" "base_url = \"${QW_BASE}\"" "${qw_cfg}"
check_contains "QwenCloud stores only the selected credential env name" 'api_key_env = "DASHSCOPE_API_KEY"' "${qw_cfg}"
check_contains "qwen4-max-preview is registered" '[models."qwencloud/qwen4-max-preview"]' "${qw_cfg}"
check_contains "other served chat models are registered" '[models."qwencloud/deepseek-v4.1-flash"]' "${qw_cfg}"
check_contains "qwen launch pins the default alias" 'default_model = "qwencloud/qwen4-max-preview"' "${qw_cfg}"
check_not_contains "audio models are filtered" "qwen-audio" "${qw_cfg}"
check_not_contains "image models are filtered" "qwen-image" "${qw_cfg}"
check_not_contains "video models are filtered" "wan3.0-video" "${qw_cfg}"
check_contains "unrelated provider is preserved" "[providers.unrelated]" "${qw_cfg}"
check_not_contains "QwenCloud credential is never written" "${QW_KEY}" "${qw_cfg}"

echo "[*] Kalidroid catalogue replaces old Kimi providers"
MIGRATE_CONFIG="${TMPDIR_A}/migrate/config.toml"
mkdir -p "$(dirname "${MIGRATE_CONFIG}")"
cat > "${MIGRATE_CONFIG}" <<'TOML'
default_model = "ollama-old/local:latest"
[providers.ollama-old]
type = "openai"
base_url = "http://old.invalid/v1"
api_key = "ollama"
[providers.vllm]
type = "openai"
base_url = "http://old-vllm.invalid/v1"
api_key = "EMPTY"
[providers.ollama-cloud]
type = "openai"
base_url = "https://ollama.com/v1"
api_key_env = "OLLAMA_API_KEY"
[providers.unrelated]
type = "openai"
base_url = "https://unrelated.invalid/v1"
api_key_env = "UNRELATED_API_KEY"
[providers.ollamaresearch]
type = "openai"
base_url = "https://research.invalid/v1"
api_key_env = "RESEARCH_API_KEY"
[models."ollama-old/local:latest"]
provider = "ollama-old"
model = "local:latest"
[models."vllm/org/model"]
provider = "vllm"
model = "org/model"
[models."ollama-cloud/beam"]
provider = "ollama-cloud"
model = "beam"
[models."ollamaresearch/custom"]
provider = "ollamaresearch"
model = "custom"
[thinking]
enabled = true
effort = "high"
TOML
rm -f "${CAPTURE}" "${CURL_LOG}"
KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${MIGRATE_CONFIG}" \
    "${KIMO}" launch kimi --model qwen3.8-27b-uncensored >/dev/null 2>&1
check "catalogue launch does not pin a direct alias" "no" "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
check "catalogue launch uses the served model in the env channel" "qwen3.8-27b-uncensored" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "catalogue launch uses the OpenAI wire" "openai" "$(env_val "${CAPTURE}" KIMI_MODEL_PROVIDER_TYPE)"
check "catalogue launch routes through the loopback shim" "yes" \
    "$(case "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)" in http://127.0.0.1:*/v1) echo yes ;; *) echo no ;; esac)"
check "shim launch carries the token" "${KD_KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "shim launch carries the served context" "131072" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check "shim launch carries capabilities" "thinking,tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "shim launch carries the reasoning key" "reasoning_content" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "shim launch carries the fitted effort" "medium" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check "Kimi receives the Kalidroid token by env name" "${KD_KEY}" "$(env_val "${CAPTURE}" KALIDROID_API_KEY)"
check "the live catalogue was fetched" "yes" "$(grep -q "URL ${KD_BASE}/models" "${CURL_LOG}" && echo yes || echo no)"
check "catalogue request carries the bearer token" "yes" "$(grep -q "Authorization: Bearer ${KD_KEY}" "${CURL_LOG}" && echo yes || echo no)"
cfg=$(cat "${MIGRATE_CONFIG}")
check_contains "Kalidroid provider is registered" "[providers.kalidroid]" "${cfg}"
check_contains "Kalidroid base URL is registered" "base_url = \"${KD_BASE}\"" "${cfg}"
check_contains "credential is an environment reference" 'api_key_env = "KALIDROID_API_KEY"' "${cfg}"
check_not_contains "token is never written to config" "${KD_KEY}" "${cfg}"
check_contains "first served model is registered" '[models."kalidroid/qwen3.8-27b-uncensored"]' "${cfg}"
check_contains "second served model is registered" '[models."kalidroid/kimi-k3.1-pro"]' "${cfg}"
model_block() {
    awk -v alias="[models.\"kalidroid/$1\"]" '$0 == alias { found = 1; next } found && /^\[/ { exit } found' <<<"${cfg}"
}
qwen_cfg=$(model_block "qwen3.8-27b-uncensored")
check_contains "Qwen3.8 gets its template's effort set" 'support_efforts = ["low", "medium", "xhigh"]' "${qwen_cfg}"
check_contains "Qwen3.8 default effort avoids high" 'default_effort = "medium"' "${qwen_cfg}"
check_contains "Qwen3.8 off effort disables reasoning" 'off_effort = "none"' "${qwen_cfg}"
k3_cfg=$(model_block "kimi-k3.1-pro")
check_contains "other models keep the graded effort range" 'support_efforts = ["low", "medium", "high", "xhigh", "max"]' "${k3_cfg}"
check_contains "other models keep high as their default" 'default_effort = "high"' "${k3_cfg}"
check_contains "other models keep low as off" 'off_effort = "low"' "${k3_cfg}"
think_cfg=$(awk '/^\[thinking\]/{ found = 1; next } found && /^\[/ { exit } found' <<<"${cfg}")
check_contains "the global effort is fitted to the launched model" 'effort = "medium"' "${think_cfg}"
check_not_contains "the rejected global effort is gone" 'effort = "high"' "${think_cfg}"
check_contains "served context is registered" "max_context_size = 262144" "${cfg}"
check_contains "default model selects Kalidroid" 'default_model = "kalidroid/qwen3.8-27b-uncensored"' "${cfg}"
check_not_contains "non-chat models are filtered" "text-embedding-v4" "${cfg}"
check_not_contains "old Ollama provider is removed" "[providers.ollama-old]" "${cfg}"
check_not_contains "old Ollama alias is removed" 'ollama-old/' "${cfg}"
check_not_contains "old vLLM provider is removed" "[providers.vllm]" "${cfg}"
check_not_contains "old vLLM alias is removed" 'vllm/org/' "${cfg}"
check_contains "Ollama Cloud provider is preserved" "[providers.ollama-cloud]" "${cfg}"
check_contains "Ollama Cloud alias is preserved" '[models."ollama-cloud/beam"]' "${cfg}"
check_contains "unrelated providers are preserved" "[providers.unrelated]" "${cfg}"
check_contains "similarly named custom provider is preserved" "[providers.ollamaresearch]" "${cfg}"
check_contains "similarly named custom alias is preserved" '[models."ollamaresearch/custom"]' "${cfg}"

echo "[*] Loopback chat proxy separates inline reasoning"
proxy_ok="$(python3 - "${ROOT_DIR}/lib/kimo-chat-proxy.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("chat_proxy", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

lt, gt = chr(60), chr(62)
open_tag = lt + "think" + gt
close_tag = lt + "/think" + gt
model = "qwen3.8-27b-uncensored"

# The wire shape that caused the report: the template opened the block, so the
# output is reasoning, a bare close, then the answer.
split = mod.split_inline("Let me plan.\n\n" + close_tag + "\n\nI'll start.", model)
assert split["reasoning_content"].strip() == "Let me plan.", split
assert split["content"] == "I'll start.", split

# The close tag split across streamed chunks.
splitter = mod.InlineThinkSplitter(model)
parts = []
for chunk in ("Let me ", "plan.\n\n" + lt + "/thi", "nk" + gt + "\n\nI'll ", "start."):
    parts.extend(splitter.feed(chunk))
parts.extend(splitter.finish())
thinking = "".join(piece for kind, piece in parts if kind == "reasoning_content")
content = "".join(piece for kind, piece in parts if kind == "content")
assert thinking.strip() == "Let me plan.", (thinking, content)
assert content == "I'll start.", (thinking, content)

# A model that does not open thinking keeps plain answers and comparisons.
assert not mod.opens_in_prompt("qwen3.8-coder")
assert mod.split_inline("2 < 3", "llama3.2:1b")["content"] == "2 < 3"
explicit = mod.split_inline("a " + open_tag + "b" + close_tag + " c", "llama3.2:1b")
assert explicit["reasoning_content"] == "b", explicit
assert explicit["content"] == "a c", explicit

# The stream transform emits reasoning and answer on separate deltas.
transform = mod.Transform(model, None)
first = transform.chunk({"choices": [{"index": 0, "delta": {"content": "plan\n\n"}}]})
assert first[0]["choices"][0]["delta"].get("reasoning_content") == "plan\n\n", first
second = transform.chunk({"choices": [{"index": 0, "delta": {"content": close_tag + "\n\nanswer"}}]})
assert second[0]["choices"][0]["delta"].get("content") == "answer", second
assert "reasoning_content" not in second[0]["choices"][0]["delta"], second

# A whole JSON reply gets the same split.
whole = transform.chat({"choices": [{"index": 0, "message": {"role": "assistant", "content": "plan\n\n" + close_tag + "\n\nanswer"}}]})
assert whole["choices"][0]["message"]["content"] == "answer", whole
assert whole["choices"][0]["message"]["reasoning_content"].strip() == "plan", whole
print("chat-proxy-ok")
PY
)"
check "the chat proxy separates inline reasoning" "chat-proxy-ok" "${proxy_ok}"

echo "[*] Catalogue failure fallback and authentication failure"
FALLBACK_CONFIG="${TMPDIR_A}/fallback/config.toml"
mkdir -p "$(dirname "${FALLBACK_CONFIG}")"
printf '[thinking]\nenabled = true\neffort = "high"\n' > "${FALLBACK_CONFIG}"
rm -f "${CAPTURE}"
KD_FAKE_STATUS=000 KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${FALLBACK_CONFIG}" \
    "${KIMO}" launch kimi --model qwen3.8-27b-uncensored >/dev/null 2>&1
check "unreachable catalogue uses the model env channel" "qwen3.8-27b-uncensored" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "env channel uses the OpenAI wire" "openai" "$(env_val "${CAPTURE}" KIMI_MODEL_PROVIDER_TYPE)"
check "env channel uses the Kalidroid base" "${KD_BASE}" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
check "env channel carries the token" "${KD_KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "env channel carries the context" "131072" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check "env channel carries capabilities" "thinking,tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "env channel carries reasoning key" "reasoning_content" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "env channel carries a fitting thinking effort" "medium" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check "env channel launches without a config alias" "no" "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
check_contains "the env fallback fits the persisted effort" 'effort = "medium"' \
    "$(awk '/^\[thinking\]/{f=1;next} f&&/^\[/{exit} f' "${FALLBACK_CONFIG}")"

echo "[*] Qwen3.8 effort overrides fit the served template"
MAX_CONFIG="${TMPDIR_A}/max/config.toml"
rm -f "${CAPTURE}"
KIMO_KIMI_EFFORT=max KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${MAX_CONFIG}" \
    "${KIMO}" launch kimi --model qwen3.8-27b-uncensored >/dev/null 2>&1
max_cfg=$(cat "${MAX_CONFIG}")
check_contains "max maps to the Qwen3.8 ceiling" 'default_effort = "xhigh"' "${max_cfg}"
rm -f "${CAPTURE}"
KIMO_KIMI_EFFORT=max KD_FAKE_STATUS=000 KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${TMPDIR_A}/max/fallback.toml" \
    "${KIMO}" launch kimi --model qwen3.8-27b-uncensored >/dev/null 2>&1
check "the env fallback also caps max" "xhigh" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
K3_CONFIG="${TMPDIR_A}/k3/config.toml"
mkdir -p "$(dirname "${K3_CONFIG}")"
printf '[thinking]\nenabled = true\neffort = "high"\n' > "${K3_CONFIG}"
KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${K3_CONFIG}" \
    "${KIMO}" launch kimi --model kimi-k3.1-pro >/dev/null 2>&1
check "an allowed global effort is preserved" "high" \
    "$(sed -n 's/^effort = "\(.*\)"$/\1/p' "${K3_CONFIG}")"

REJECT_CONFIG="${TMPDIR_A}/reject/config.toml"
mkdir -p "$(dirname "${REJECT_CONFIG}")"
printf '[providers.existing]\ntype = "openai"\n' > "${REJECT_CONFIG}"
reject_before=$(cksum "${REJECT_CONFIG}")
rm -f "${CAPTURE}"
rc=0
rejected=$(KD_FAKE_STATUS=401 KALIDROID_API_KEY="${KD_KEY}" KIMI_CONFIG="${REJECT_CONFIG}" \
    "${KIMO}" launch kimi 2>&1) || rc=$?
check "a rejected Kalidroid token aborts" 1 "${rc}"
check_contains "authentication error names Kalidroid" "Kalidroid" "${rejected}"
check_not_contains "authentication error never prints the token" "${KD_KEY}" "${rejected}"
check "rejected token never execs Kimi" "no" "$([[ -f "${CAPTURE}" ]] && echo yes || echo no)"
check "rejected token preserves existing config" "${reject_before}" "$(cksum "${REJECT_CONFIG}")"

echo "[*] Kimi web/rc arguments still pass through"
dry=$(KALIDROID_API_KEY="${KD_KEY}" "${KIMO}" launch kimi web --host 192.168.1.111 --port 1337 --dry-run)
check_contains "dry run includes web host and port" "web --host 192.168.1.111 --port 1337" "${dry}"
rm -f "${CAPTURE}"
KALIDROID_API_KEY="${KD_KEY}" "${KIMO}" launch kimi web --host 192.168.1.111 --port 1337 >/dev/null 2>&1
check "Kimi receives --host" "192.168.1.111" "$(flag_val "${CAPTURE}" --host)"
check "Kimi receives --port" "1337" "$(flag_val "${CAPTURE}" --port)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless Kalidroid turn through kimo"
    harness_use_real_env
    if ! command -v kimi >/dev/null 2>&1; then
        echo "  SKIP kimi CLI not found"
    elif [[ -z "${KALIDROID_API_KEY:-}" ]]; then
        echo "  SKIP KALIDROID_API_KEY is not set"
    else
        smoke_home="${TMPDIR_A}/kimi-home"
        mkdir -p "${smoke_home}"
        model="${KIMO_SMOKE_MODEL:-qwen3.8-27b-uncensored}"
        set +e
        KIMI_CODE_HOME="${smoke_home}" timeout 300 "${KIMO}" launch kimi --model "${model}" \
            -p "Reply with exactly: PONG" >"${smoke_home}/run.out" 2>&1
        live_rc=$?
        set -e
        if [[ "${live_rc}" -eq 0 ]] && grep -qi 'PONG' "${smoke_home}/run.out"; then
            ok "live Kalidroid answer contains PONG"
        else
            bad "live Kalidroid turn failed (rc=${live_rc}): $(tail -c 200 "${smoke_home}/run.out")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
