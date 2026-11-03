#!/usr/bin/env bash
# Codex launch on DashScope, QwenCloud, xAI Grok and Anthropic.
#
# Asserts that 'kimo launch codex --provider <name>' points Codex at that
# provider's Responses endpoint via -c overlays, keeps the credential in the
# named environment variable, and does not write config.toml or pass --oss.
#
# Usage: tests/codex_providers_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

unset DASHSCOPE_API_KEY MODELSTUDIO_API_KEY QWENCLOUD_API_KEY XAI_API_KEY XAI_AUTH_TOKEN \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
    GEMINI_API_KEY GEMINI_AUTH_TOKEN GOOGLE_API_KEY GOOGLE_OAUTH_TOKEN \
    KIMO_QWENCLOUD_BASE_URL KIMO_QWENCLOUD_REGION KIMO_XAI_BASE_URL \
    KIMO_ANTHROPIC_BASE_URL KIMO_GEMINI_BASE_URL KIMO_CLOUD_PROVIDER

FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/codex-call.txt"
CODEX_DIR="${HARNESS_ROOT}/codex-home"
mkdir -p "${FAKE_BIN}" "${CODEX_DIR}"
printf 'model = "sentinel-do-not-touch"\n' > "${CODEX_DIR}/config.toml"
SENTINEL="$(cksum "${CODEX_DIR}/config.toml")"
export CODEX_HOME="${CODEX_DIR}"
export CODEX_PROVIDERS_CAPTURE="${CAPTURE}"

cat > "${FAKE_BIN}/codex" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in DASHSCOPE_API_KEY MODELSTUDIO_API_KEY QWENCLOUD_API_KEY XAI_API_KEY \
        ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_BASE_URL CODEX_OSS_BASE_URL \
        OLLAMA_HOST OPENAI_API_KEY KIMO_RESPONSES_UPSTREAM; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${CODEX_PROVIDERS_CAPTURE:?}"
printf '{"native":true}\n'
exit 0
SH
chmod +x "${FAKE_BIN}/codex"
export PATH="${FAKE_BIN}:${PATH}"

DS_KEY="sk-dashscope-fixture-12345"
SP_KEY="sk-sp-token-plan-fixture-67890"
QW_KEY="sk-qwencloud-fixture-abc"
XAI_KEY="xai-fixture-key-999"
ANT_KEY="sk-ant-fixture-key-42"
DS_HOST="https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
DS_PLAN="https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
QW_HOST="https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1"
QW_PLAN="https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"
XAI_HOST="https://api.x.ai/v1"
ANT_HOST="https://api.anthropic.com/v1"
GM_KEY="AIzaSy-fixture-key-42"
GM_TOK="ya29.fixture-token-42"
GM_HOST="https://generativelanguage.googleapis.com/v1beta/openai"

# <label> <provider> <host> <model> <env-var> <ctx>
expect_responses() {
    local label="$1" provider="$2" host="$3" model="$4" env_key="$5" ctx="$6" dry="$7"
    check_contains "${label}: provider" "provider: ${provider}" "${dry}"
    check_contains "${label}: host" "host   : ${host}" "${dry}"
    check_contains "${label}: model" "model  : ${model}" "${dry}"
    check_contains "${label}: wire" "wire   : responses (${host})" "${dry}"
    check_contains "${label}: context" "context: ${ctx} tokens" "${dry}"
    check_contains "${label}: no --oss" "argv   :" "${dry}"
    check_not_contains "${label}: omits --oss" "--oss" "${dry}"
    check_contains "${label}: model_provider" "model_provider=\\\"${provider}\\\"" "${dry}"
    check_contains "${label}: base_url" "base_url=\\\"${host}\\\"" "${dry}"
    check_contains "${label}: env_key" "env_key=\\\"${env_key}\\\"" "${dry}"
    check_contains "${label}: wire_api" 'wire_api=\"responses\"' "${dry}"
    check_contains "${label}: no openai auth" "requires_openai_auth=false" "${dry}"
    check_contains "${label}: window" "model_context_window=${ctx}" "${dry}"
    check_contains "${label}: --model" "--model ${model}" "${dry}"
    check_contains "${label}: catalog_url" "model_providers.${provider}.model_catalog_url=\\\"${host}/models\\\"" "${dry}"
    check_contains "${label}: namespace tools off" "--disable multi_agent" "${dry}"
    check_contains "${label}: multi_agent_v2 off" "--disable multi_agent_v2" "${dry}"
    check_contains "${label}: apps disabled" "--disable apps" "${dry}"
}

echo "[*] [1] DashScope on Codex"
dry=$(DASHSCOPE_API_KEY="${DS_KEY}" "${KIMO}" launch codex --provider dashscope --dry-run)
expect_responses "dashscope" dashscope "${DS_HOST}" qwen3.8-max DASHSCOPE_API_KEY 1000000 "${dry}"
check_contains "dashscope key is masked" "secret : DASHSCOPE_API_KEY <kept: real value, DashScope key>" "${dry}"
check_not_contains "dry-run never prints the dashscope key" "${DS_KEY}" "${dry}"
check_contains "dashscope notes config.toml is untouched" "config.toml is not modified" "${dry}"
dry=$(DASHSCOPE_API_KEY="${DS_KEY}" "${KIMO}" launch codex --provider dashscope --model dashscope/qwen3-coder-plus --ctx 4096 --dry-run)
check_contains "dashscope/ prefix is stripped" "model  : qwen3-coder-plus" "${dry}"
check_contains "--ctx overrides the window" "model_context_window=4096" "${dry}"
dry=$(DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider dashscope --dry-run)
check_contains "sk-sp selects the DashScope plan host" "host   : ${DS_PLAN}" "${dry}"
dry=$(MODELSTUDIO_API_KEY="${DS_KEY}" "${KIMO}" launch codex --provider dashscope --dry-run)
check_contains "MODELSTUDIO_API_KEY is the env_key" 'env_key=\"MODELSTUDIO_API_KEY\"' "${dry}"

echo "[*] [2] QwenCloud"
dry=$(QWENCLOUD_API_KEY="${QW_KEY}" "${KIMO}" launch codex --provider qwencloud --dry-run)
expect_responses "qwencloud" qwencloud "${QW_HOST}" qwen3.8-max QWENCLOUD_API_KEY 1000000 "${dry}"
check_contains "qwencloud key is masked" "secret : QWENCLOUD_API_KEY <kept: real value, QwenCloud key>" "${dry}"
check_not_contains "dry-run never prints the qwencloud key" "${QW_KEY}" "${dry}"
dry=$(DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider qwencloud --dry-run)
check_contains "sk-sp selects the QwenCloud plan host" "host   : ${QW_PLAN}" "${dry}"
check_contains "plan key is named DASHSCOPE_API_KEY" 'env_key=\"DASHSCOPE_API_KEY\"' "${dry}"
dry=$(KIMO_QWENCLOUD_REGION=us-east-1 QWENCLOUD_API_KEY="${QW_KEY}" "${KIMO}" launch codex --provider qwencloud --dry-run)
check_contains "region override changes the host" "host   : https://us-east-1.maas.qwencloudapi.com/compatible-mode/v1" "${dry}"
dry=$(KIMO_QWENCLOUD_BASE_URL=https://example.invalid/v1 DASHSCOPE_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider qwencloud --dry-run)
check_contains "explicit base URL wins over the plan host" "host   : https://example.invalid/v1" "${dry}"
dry=$(QWENCLOUD_API_KEY="${QW_KEY}" "${KIMO}" launch codex --provider qwencloud --model qwencloud/qwen3-coder-plus --dry-run)
check_contains "qwencloud/ prefix is stripped" "model  : qwen3-coder-plus" "${dry}"

echo "[*] [3] xAI Grok"
dry=$(XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --provider xai --dry-run)
expect_responses "xai" xai "${XAI_HOST}" grok-4.7 XAI_API_KEY 500000 "${dry}"
check_contains "xai key is masked" "secret : XAI_API_KEY <kept: real value, xAI key>" "${dry}"
check_not_contains "dry-run never prints the xai key" "${XAI_KEY}" "${dry}"
check_contains "xai display name keeps the space" 'name=\"xAI\ Grok\"' "${dry}"
dry=$(XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --provider grok --model grok/grok-4.6 --dry-run)
check_contains "grok is an alias of xai" "provider: xai" "${dry}"
check_contains "grok/ prefix is stripped" "model  : grok-4.6" "${dry}"
dry=$(KIMO_XAI_BASE_URL=https://us.api.x.ai/v1 XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --provider xai --dry-run)
check_contains "xai base URL override" "host   : https://us.api.x.ai/v1" "${dry}"
dry=$(XAI_API_KEY="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyIn0.mock" "${KIMO}" launch codex --provider xai --dry-run)
check_contains "xai accepts JWT in XAI_API_KEY" "provider: xai" "${dry}"
dry=$(XAI_AUTH_TOKEN="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyIn0.mock" "${KIMO}" launch codex --provider xai --dry-run)
check_contains "xai accepts XAI_AUTH_TOKEN" "provider: xai" "${dry}"
check_contains "xai env_key is XAI_AUTH_TOKEN" 'env_key=\"XAI_AUTH_TOKEN\"' "${dry}"

echo "[*] [4] Anthropic"
dry=$(ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" launch codex --provider anthropic --dry-run)
expect_responses "anthropic" anthropic "${ANT_HOST}" claude-opus-5-5 ANTHROPIC_API_KEY 1000000 "${dry}"
check_contains "anthropic key is masked" "secret : ANTHROPIC_API_KEY <kept: real value, Anthropic key>" "${dry}"
check_not_contains "dry-run never prints the anthropic key" "${ANT_KEY}" "${dry}"
dry=$(ANTHROPIC_AUTH_TOKEN="${ANT_KEY}" "${KIMO}" launch codex --provider anthropic --model anthropic/claude-sonnet-5-5 --dry-run)
check_contains "AUTH_TOKEN is accepted" 'env_key=\"ANTHROPIC_AUTH_TOKEN\"' "${dry}"
check_contains "anthropic/ prefix is stripped" "model  : claude-sonnet-5-5" "${dry}"
# A Claude Code ANTHROPIC_BASE_URL must not retarget the Responses base.
dry=$(ANTHROPIC_BASE_URL=https://claude.example.invalid ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" launch codex --provider anthropic --dry-run)
check_contains "ANTHROPIC_BASE_URL is not the Codex origin" "host   : ${ANT_HOST}" "${dry}"
dry=$(ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" launch codex --provider claude --dry-run)
check_contains "claude is an alias of anthropic" "provider: anthropic" "${dry}"

echo "[*] [4.5] Gemini on Codex"
dry=$(GEMINI_API_KEY="${GM_KEY}" "${KIMO}" launch codex --provider gemini --dry-run)
expect_responses "gemini" gemini "${GM_HOST}" gemini-2.5-flash GEMINI_API_KEY 1000000 "${dry}"
check_contains "gemini key is masked" "secret : GEMINI_API_KEY <kept: real value, Gemini key>" "${dry}"
check_not_contains "dry-run never prints the gemini key" "${GM_KEY}" "${dry}"
dry=$(GEMINI_AUTH_TOKEN="${GM_TOK}" "${KIMO}" launch codex --provider gemini --model gemini/gemini-2.5-pro --dry-run)
check_contains "AUTH_TOKEN is accepted for gemini" 'env_key=\"GEMINI_AUTH_TOKEN\"' "${dry}"
check_contains "gemini/ prefix is stripped" "model  : gemini-2.5-pro" "${dry}"
rc=0
err_gm_guard=$(GEMINI_API_KEY="${GM_KEY}" "${KIMO}" launch codex --provider gemini 2>&1) || rc=$?
check "gemini without custom base fails official endpoint guard" 1 "${rc}"
check_contains "guard mentions lack of responses API" "does not support the OpenAI Responses API" "${err_gm_guard}"

echo "[*] [5] Credentials, supported CLIs, config and scrubbing"
rc=0
nokey=$("${KIMO}" launch codex --provider qwencloud --dry-run 2>&1) || rc=$?
check "a missing qwencloud key fails" 1 "${rc}"
check_contains "the error names QWENCLOUD_API_KEY" "QWENCLOUD_API_KEY" "${nokey}"
rc=0
QWENCLOUD_API_KEY=ollama "${KIMO}" launch codex --provider qwencloud --dry-run >/dev/null 2>&1 || rc=$?
check "the ollama placeholder is not a QwenCloud key" 1 "${rc}"
rc=0
XAI_API_KEY=ollama "${KIMO}" launch codex --provider xai --dry-run >/dev/null 2>&1 || rc=$?
check "the ollama placeholder is not an xAI key" 1 "${rc}"
rc=0
bad=$("${KIMO}" launch kimi --provider xai --dry-run 2>&1) || rc=$?
check "xai is codex-only" 1 "${rc}"
check_contains "the rejection names codex" "supports codex" "${bad}"
rc=0
badurl=$(KIMO_XAI_BASE_URL='http://api.x.ai/v1' XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --provider xai --dry-run 2>&1) || rc=$?
check "a non-https base URL is rejected" 1 "${rc}"
check_contains "the error names the base URL" "https URL" "${badurl}"
"${KIMO}" config set cloud_provider qwencloud >/dev/null
check "config accepts qwencloud" qwencloud "$("${KIMO}" config get cloud_provider)"
"${KIMO}" config set cloud_provider grok >/dev/null
dry=$(XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --dry-run)
check_contains "config grok normalizes to xai" "provider: xai" "${dry}"
"${KIMO}" config unset cloud_provider >/dev/null
rc=0
bogus=$("${KIMO}" config set cloud_provider not-a-provider 2>&1) || rc=$?
check "an unknown backend is rejected" 1 "${rc}"
check_contains "the rejection lists qwencloud" "qwencloud" "${bogus}"

XAI_API_KEY="${XAI_KEY}" QWENCLOUD_API_KEY="${QW_KEY}" "${KIMO}" --host http://remote.kimo-test.invalid:9 \
    launch codex --provider ollama --model test-local >/dev/null 2>&1
check "remote Ollama clears XAI_API_KEY" "<unset>" "$(env_val "${CAPTURE}" XAI_API_KEY)"
check "remote Ollama clears QWENCLOUD_API_KEY" "<unset>" "$(env_val "${CAPTURE}" QWENCLOUD_API_KEY)"

echo "[*] [6] Launch argv, env and an untouched Codex config"
DASHSCOPE_API_KEY="${DS_KEY}" "${KIMO}" launch codex --provider dashscope -- exec --json 'hello world' >/dev/null 2>&1
check "exec receives the model" "qwen3.8-max" "$(flag_val "${CAPTURE}" --model)"
check_contains "exec disables the namespace multi-agent tool" $'--disable\nmulti_agent\n' "$(cat "${CAPTURE}")"
check_contains "exec disables multi_agent_v2" $'--disable\nmulti_agent_v2\n' "$(cat "${CAPTURE}")"
check_contains "exec carries the provider id" 'model_provider="dashscope"' "$(cat "${CAPTURE}")"
check_contains "exec points Codex at the local flattener" "127.0.0.1" "$(cat "${CAPTURE}")"
check "the proxy keeps the real DashScope upstream" "${DS_HOST}" "$(env_val "${CAPTURE}" KIMO_RESPONSES_UPSTREAM)"
check_contains "runtime flags follow exec" $'exec\n--model\nqwen3.8-max' "$(cat "${CAPTURE}")"
check "the child sees the dashscope key" "${DS_KEY}" "$(env_val "${CAPTURE}" DASHSCOPE_API_KEY)"
check "stale OPENAI_BASE_URL is unset" "<unset>" "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
check "CODEX_OSS_BASE_URL is unset" "<unset>" "$(env_val "${CAPTURE}" CODEX_OSS_BASE_URL)"
argv_only="$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}")"
check_not_contains "the key is not an argument" "${DS_KEY}" "${argv_only}"

XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch codex --provider xai -- review >/dev/null 2>&1
check_contains "review sets model_provider via -c" 'model_provider="xai"' "$(cat "${CAPTURE}")"
check_contains "review sets the model via -c" 'model="grok-4.7"' "$(cat "${CAPTURE}")"
check_not_contains "review does not take --model" $'--model\n' "$(cat "${CAPTURE}")"
check "review sees the xai key" "${XAI_KEY}" "$(env_val "${CAPTURE}" XAI_API_KEY)"

check "Codex config.toml is unchanged" "${SENTINEL}" "$(cksum "${CODEX_DIR}/config.toml")"

echo "[*] [7] Namespace tools are flattened before the upstream"
UPSTREAM="${HARNESS_ROOT}/upstream-body.json"
python3 - << PY &
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(n)
        open("${UPSTREAM}", "wb").write(body)
        raw = b'{"id":"resp_test","object":"response","status":"completed","output":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def log_message(self, fmt, *args):
        return
ThreadingHTTPServer(("127.0.0.1", 8877), H).serve_forever()
PY
UP_PID=$!
sleep 0.2
PORT_FILE="${HARNESS_ROOT}/proxy-port"
python3 "${ROOT_DIR}/lib/kimo-responses-proxy.py" --upstream "http://127.0.0.1:8877/v1" --port-file "${PORT_FILE}" --exit-with-pid "$$" >/dev/null 2>&1 &
PROXY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "${PORT_FILE}" ]] && break
    sleep 0.1
done
PROXY_PORT=$(tr -cd '0-9' <"${PORT_FILE}")
BODY='{"model":"grok-4.7","input":"tell me a joke","tool_choice":{"type":"web_search","external_web_access":true,"search_context_size":"low"},"tools":[{"type":"function","name":"exec_command","parameters":{"type":"object","properties":{"external_web_access":{"type":"boolean"}}}},{"type":"namespace","name":"mcp__codex_worktrees","tools":[{"type":"function","name":"list_worktrees","description":"list"}]},{"type":"namespace","name":"mcp__codex_apps","tools":[{"type":"function","name":"browse","description":"browse"}]},{"type":"function","name":"mcp__codex_apps__action"},{"type":"web_search","external_web_access":false,"search_context_size":"low"},{"type":"web_search"},{"type":"web_search","external_web_access":true,"indexed_web_access":true,"search_context_size":"medium","filters":{"allowed_domains":["example.com"]},"user_location":{"type":"approximate","city":"Oslo"},"search_content_types":["text"]}]}'
curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/responses" -H 'Content-Type: application/json' -d "${BODY}" >/dev/null
python3 - << PY
import json
body=json.load(open("${UPSTREAM}"))
types=[t.get("type") for t in body["tools"]]
names=[t.get("name") for t in body["tools"]]
assert "namespace" not in types, types
assert "mcp__codex_worktrees__list_worktrees" in names, names
assert "exec_command" in names, names
assert not any("codex_apps" in str(n) for n in names), f"codex_apps leaked into upstream tools: {names}"
fn=[t for t in body["tools"] if t.get("name")=="exec_command"][0]
assert "external_web_access" in fn["parameters"]["properties"], fn
web=[t for t in body["tools"] if str(t.get("type","")).startswith("web_search")]
assert len(web)==2, web
assert all("external_web_access" not in t and "indexed_web_access" not in t and "search_context_size" not in t for t in web), web
bare=[t for t in web if "filters" not in t]
assert bare==[{"type":"web_search"}], bare
kept=[t for t in web if "filters" in t][0]
assert kept["filters"]=={"allowed_domains":["example.com"]}, kept
assert kept["user_location"]["city"]=="Oslo", kept
assert kept["search_content_types"]==["text"], kept
assert body["tool_choice"]=={"type":"web_search"}, body["tool_choice"]
print("flattened", names)
PY
kill "${PROXY_PID}" "${UP_PID}" 2>/dev/null || true
wait "${PROXY_PID}" "${UP_PID}" 2>/dev/null || true
check "namespace tools are flattened upstream" flattened flattened

echo "[*] [8] No Ollama probing"
cat > "${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_PROVIDERS_CAPTURE}.curl"
exit 7
SH
chmod +x "${FAKE_BIN}/curl"
( unset OLLAMA_REMOTE_URL; ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" --remote launch codex --provider anthropic --dry-run >/dev/null )
check "anthropic routing never probes Ollama" no "$([[ -f "${CAPTURE}.curl" ]] && echo yes || echo no)"
rm -f "${FAKE_BIN}/curl"

echo "[*] [9] Proxy serves models catalog for codex model_catalog_url"
PORT_FILE=$(mktemp "${HARNESS_ROOT}/models-port.XXXXXX")
python3 "${ROOT_DIR}/lib/kimo-responses-proxy.py" \
    --upstream "http://127.0.0.1:9" \
    --provider dashscope \
    --model custom-test-model \
    --port-file "${PORT_FILE}" \
    --exit-with-pid "$$" >/dev/null 2>&1 &
CATALOG_PROXY_PID=$!
waited=0
while [[ ! -s "${PORT_FILE}" ]] && ((waited < 30)); do
    sleep 0.1
    waited=$((waited + 1))
done
CAT_PORT=$(tr -cd '0-9' <"${PORT_FILE}")
rm -f "${PORT_FILE}"
models_resp=$(curl -sS -m 5 "http://127.0.0.1:${CAT_PORT}/models")
v1_models_resp=$(curl -sS -m 5 "http://127.0.0.1:${CAT_PORT}/v1/models?client_version=0.164.0")
kill "${CATALOG_PROXY_PID}" 2>/dev/null || true
wait "${CATALOG_PROXY_PID}" 2>/dev/null || true
check "proxy /models returns valid json" "true" "$(python3 -c 'import json,sys; sys.exit(0 if isinstance(json.loads(sys.argv[1]), dict) else 1)' "${models_resp}" && echo true || echo false)"
check_contains "proxy /models includes default model" "qwen3.8-max" "${models_resp}"
check_contains "proxy /models includes explicit extra model" "custom-test-model" "${models_resp}"
check_contains "proxy /v1/models with query serves catalog" "qwen3.8-max" "${v1_models_resp}"

echo "[*] [10] Shell completions populate available models for CLI"
COMP_SCRIPT="${HARNESS_ROOT}/comp_test.bash"
"${KIMO}" completion bash > "${COMP_SCRIPT}"
comp_ds=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider dashscope -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers dashscope models with prefix" "dashscope/qwen3.8-max" "${comp_ds}"
check_contains "completion offers dashscope models bare" "qwen3.8-max" "${comp_ds}"

comp_qw=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider qwencloud -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers qwencloud models" "qwencloud/qwen3.8-max" "${comp_qw}"

comp_xai=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider xai -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers xai models" "xai/grok-4.7" "${comp_xai}"

comp_ant=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider anthropic -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers anthropic models" "anthropic/claude-opus-5-5" "${comp_ant}"

comp_claude=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider claude -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers claude models" "claude/claude-opus-5-5" "${comp_claude}"

comp_gm=$(bash -c "source '${COMP_SCRIPT}'; COMP_WORDS=(kimo launch codex --provider gemini -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers gemini models with prefix" "gemini/gemini-2.5-flash" "${comp_gm}"
check_contains "completion offers gemini models bare" "gemini-2.5-flash" "${comp_gm}"

echo "[*] [11] API configuration validation on launch codex"
rc=0
err_codex_auth=$(CODEX_AUTH_TOKEN="" CODEX_API_KEY="" HOME="${HARNESS_ROOT}/nonexistent_home" "${KIMO}" launch codex --provider codex --dry-run 2>&1) || rc=$?
check "launch codex --provider codex fails without OAuth token" 1 "${rc}"
check_contains "error message mentions OAuth token" "ChatGPT OAuth token" "${err_codex_auth}"

rc=0
err_codex_url=$(CODEX_AUTH_TOKEN="${DS_KEY}" KIMO_CODEX_BACKEND_URL="http://insecure.url" "${KIMO}" launch codex --provider codex --dry-run 2>&1) || rc=$?
check "launch codex --provider codex fails on non-https base URL" 1 "${rc}"
check_contains "error message mentions Codex backend URL" "Codex backend URL is not an https URL" "${err_codex_url}"

rc=0
err_openai_url=$(OPENAI_API_KEY="${DS_KEY}" KIMO_OPENAI_BACKEND_URL="http://insecure.url" "${KIMO}" launch codex --provider openai --dry-run 2>&1) || rc=$?
check "launch codex --provider openai fails on non-https base URL" 1 "${rc}"
check_contains "error message mentions OpenAI base URL" "OpenAI base URL is not an https URL" "${err_openai_url}"

rc=0
err_openai_sp=$(OPENAI_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider openai --dry-run 2>&1) || rc=$?
check "launch codex --provider openai rejects sk-sp key" 1 "${rc}"
check_contains "error message identifies DashScope token-plan key" "Alibaba DashScope token-plan key" "${err_openai_sp}"

rc=0
err_openai_fmt=$(OPENAI_API_KEY="invalid-key" "${KIMO}" launch codex --provider openai --dry-run 2>&1) || rc=$?
check "launch codex --provider openai rejects invalid format" 1 "${rc}"
check_contains "error message requires sk- prefix" "expected OpenAI platform API key format" "${err_openai_fmt}"

rc=0
err_ant_sp=$(ANTHROPIC_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider anthropic --dry-run 2>&1) || rc=$?
check "launch codex --provider anthropic rejects sk-sp key" 1 "${rc}"
check_contains "error message identifies DashScope token-plan key" "Alibaba DashScope token-plan key" "${err_ant_sp}"

rc=0
err_ant_fmt=$(ANTHROPIC_API_KEY="bad-ant-key" "${KIMO}" launch codex --provider anthropic --dry-run 2>&1) || rc=$?
check "launch codex --provider anthropic rejects non-sk-ant key" 1 "${rc}"
check_contains "error message requires sk-ant- prefix" "expected Anthropic API key format" "${err_ant_fmt}"

rc=0
err_xai_fmt=$(XAI_API_KEY="sk-bad-xai" "${KIMO}" launch codex --provider xai --dry-run 2>&1) || rc=$?
check "launch codex --provider xai rejects non-xai key" 1 "${rc}"
check_contains "error message requires xai- prefix" "expected xAI API key format" "${err_xai_fmt}"

rc=0
err_ds_fmt=$(DASHSCOPE_API_KEY="xai-bad" "${KIMO}" launch codex --provider dashscope --dry-run 2>&1) || rc=$?
check "launch codex --provider dashscope rejects non-sk key" 1 "${rc}"
check_contains "error message requires sk- prefix" "expected DashScope API key format" "${err_ds_fmt}"

rc=0
err_qw_fmt=$(QWENCLOUD_API_KEY="xai-bad" "${KIMO}" launch codex --provider qwencloud --dry-run 2>&1) || rc=$?
check "launch codex --provider qwencloud rejects non-sk key" 1 "${rc}"
check_contains "error message requires sk- prefix" "expected QwenCloud API key format" "${err_qw_fmt}"

rc=0
err_gm_sp=$(GEMINI_API_KEY="${SP_KEY}" "${KIMO}" launch codex --provider gemini --dry-run 2>&1) || rc=$?
check "launch codex --provider gemini rejects sk-sp key" 1 "${rc}"
check_contains "error message identifies DashScope token-plan key" "Alibaba DashScope token-plan key" "${err_gm_sp}"

rc=0
err_gm_fmt=$(GEMINI_API_KEY="bad-gm-key" "${KIMO}" launch codex --provider gemini --dry-run 2>&1) || rc=$?
check "launch codex --provider gemini rejects invalid format" 1 "${rc}"
check_contains "error message requires AIzaSy or ya29 prefix" "expected Gemini credential format" "${err_gm_fmt}"

echo
harness_summary "codex_providers"
