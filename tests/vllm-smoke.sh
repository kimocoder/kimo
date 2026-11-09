#!/usr/bin/env bash
# Headless smoke tests for 'launch kimi --provider vllm'.
#
# vLLM is an OpenAI-compatible server, not an Ollama daemon and not a hosted
# cloud API. These checks lock the contract:
#   * dry-run never contacts the server and never writes kimi's config
#   * the base URL is normalized (port 8000, a single /v1) from
#     KIMO_VLLM_BASE_URL, then VLLM_BASE_URL, then a global --host
#   * a served catalogue becomes [providers.<pid>] plus one alias per model
#   * the API key is referenced by name (VLLM_API_KEY) or stored as EMPTY
#   * 401/403 aborts; an unreachable server falls back only when a model was named
#   * a remote host keeps VLLM_API_KEY and scrubs unrelated credentials
#   * nothing probes Ollama, and a missing kimi binary does not exec ollama run
#
# Usage: tests/vllm-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

export KIMI_CODE_HOME="${HARNESS_ROOT}/kimi-code"
mkdir -p "${KIMI_CODE_HOME}"
KIMI_CFG="${KIMI_CODE_HOME}/config.toml"

FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/vllm-call.txt"
mkdir -p "${FAKE_BIN}"
export VLLM_TEST_CAPTURE="${CAPTURE}"
cat >"${FAKE_BIN}/kimi" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in KIMI_CODE_HOME KIMI_DISABLE_TELEMETRY KIMI_CODE_NO_AUTO_UPDATE \
        KIMI_CODE_LLM_HEADERS_TIMEOUT_MS \
        KIMI_MODEL_NAME KIMI_MODEL_API_KEY KIMI_MODEL_PROVIDER_TYPE KIMI_MODEL_BASE_URL \
        KIMI_MODEL_MAX_CONTEXT_SIZE KIMI_MODEL_CAPABILITIES KIMI_MODEL_REASONING_KEY \
        KIMI_MODEL_THINKING_EFFORT OLLAMA_HOST OPENAI_BASE_URL OPENAI_API_BASE API_BASE \
        OPENAI_API_KEY VLLM_API_KEY; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} >"${VLLM_TEST_CAPTURE:?}"
exit 0
SH
chmod +x "${FAKE_BIN}/kimi"
export PATH="${FAKE_BIN}:${PATH}"
# This machine may have a live vLLM on 127.0.0.1:8000. Do not let its key
# file change dry-runs that expect VLLM_API_KEY to be unset.
export KIMO_VLLM_NO_OWNER_KEY=1

FIXTURE="${HARNESS_ROOT}/vllm_fixture.py"
PORT_FILE="${HARNESS_ROOT}/vllm.port"
MODE_FILE="${HARNESS_ROOT}/vllm.mode"
LOG_FILE="${HARNESS_ROOT}/vllm-http.log"
printf 'ok\n' >"${MODE_FILE}"
: >"${LOG_FILE}"
cat >"${FIXTURE}" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, mode_file, log_file = sys.argv[1:4]
CATALOG = {
    "object": "list",
    "data": [
        {"id": "org/Llama-3.1-8B-Instruct", "max_model_len": 8192},
        {"id": "deepseek-ai/DeepSeek-R1", "max_model_len": 16384},
        {"id": "acme/r100", "max_model_len": 4096},
        {"id": "misc/r1-distill", "max_model_len": 2048},
    ],
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        mode = open(mode_file, encoding="utf-8").read().strip() or "ok"
        auth = self.headers.get("Authorization", "")
        with open(log_file, "a", encoding="utf-8") as fh:
            fh.write(f"{self.path}\t{auth}\n")
        if mode == "401":
            body = b'{"error":"unauthorized"}'
            code = 401
        elif mode == "302":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:9/gone")
            self.end_headers()
            return
        elif mode == "empty":
            body = b'{"data":[]}'
            code = 200
        else:
            body = json.dumps(CATALOG).encode()
            code = 200
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as fh:
    fh.write(f"{server.server_port}\n")
server.serve_forever()
PY
harness_spawn python3 "${FIXTURE}" "${PORT_FILE}" "${MODE_FILE}" "${LOG_FILE}"
tries=0
while [[ ! -s "${PORT_FILE}" ]]; do
    if ((tries++ > 100)) || ! kill -0 "${HARNESS_LAST_PID}" 2>/dev/null; then
        bad "vLLM fixture did not start"
        exit 1
    fi
    sleep 0.05
done
PORT="$(tr -cd '0-9' <"${PORT_FILE}")"
BASE="http://127.0.0.1:${PORT}/v1"
PID="vllm-127-0-0-1-${PORT}-v1"
LLAMA="org/Llama-3.1-8B-Instruct"
R1="deepseek-ai/DeepSeek-R1"
R100="acme/r100"
R1D="misc/r1-distill"

reset_kimi() { rm -rf "${KIMI_CODE_HOME}"; mkdir -p "${KIMI_CODE_HOME}"; rm -f "${CAPTURE}"; }
reset_log() { : >"${LOG_FILE}"; }
argv_of() { printf '%s\n' "$1" | sed -n 's/^  argv   : //p'; }
py() {
    python3 - "${KIMI_CFG}" "$1" <<'PY'
import sys, tomlkit
doc = tomlkit.parse(open(sys.argv[1], encoding="utf-8").read())
print(eval(sys.argv[2]))
PY
}
caps_of() {
    py '"," .join(doc["models"]["'"$1"'"]["capabilities"])'
}

echo "[1] dry-run stays local, masks secrets, and writes nothing"
reset_kimi
reset_log
rc=0
dry=$("${KIMO}" launch kimi --provider vllm --dry-run 2>"${HARNESS_ROOT}/dry.err") || rc=$?
check "dry-run exits 0" 0 "${rc}"
check_contains "provider is vllm" "provider: vllm" "${dry}"
check_contains "default host" "host   : http://127.0.0.1:8000/v1" "${dry}"
check_contains "evict is n/a" "evict  : n/a" "${dry}"
check_contains "default context" "context: 32768 tokens" "${dry}"
check_contains "openai wire" "wire   : openai http://127.0.0.1:8000/v1" "${dry}"
check "argv is bare kimi" "kimi" "$(argv_of "${dry}")"
check_contains "placeholder model" "model  : <first model vLLM is serving>" "${dry}"
check_contains "placeholder key is EMPTY" "OPENAI_API_KEY EMPTY (vLLM placeholder, no API key)" "${dry}"
check_contains "vLLM key unset" "VLLM_API_KEY <unset>" "${dry}"
check_contains "dry-run writes no config" "writes no config" "${dry}"
check "no kimi config was written" "absent" "$([[ -e "${KIMI_CFG}" ]] && echo present || echo absent)"
check "dry-run did not contact the fixture" 0 "$(wc -l <"${LOG_FILE}" | tr -d ' ')"

echo "[2] model, context, and base-URL normalization"
dry=$("${KIMO}" launch kimi --provider vllm --model "vllm/${LLAMA}" --ctx 12345 --dry-run)
check "one vllm/ prefix is stripped" "kimi -m vllm/${LLAMA}" "$(argv_of "${dry}")"
check_contains "explicit context" "context: 12345 tokens" "${dry}"
check_not_contains "dry-run does not cap without max_model_len" "Capping" "$(cat "${HARNESS_ROOT}/dry.err")"
dry=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:8000" "${KIMO}" launch kimi --provider vllm --model m --dry-run)
check_contains "bare origin gains /v1" "host   : http://127.0.0.1:8000/v1" "${dry}"
check_not_contains "no doubled /v1" "/v1/v1" "${dry}"
dry=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:8000/v1/" "${KIMO}" launch kimi --provider vllm --model m --dry-run)
check_contains "trailing slash collapses" "host   : http://127.0.0.1:8000/v1" "${dry}"
for bad in "http://127.0.0.1:8000/v1?q=1" "file:///tmp/vllm" "http://127.0.0.1:8000/v1 extra" "http://user:pass@127.0.0.1:8000/v1"; do
    rc=0
    err=$(KIMO_VLLM_BASE_URL="${bad}" "${KIMO}" launch kimi --provider vllm --dry-run 2>&1) || rc=$?
    check "rejected base (${bad%% *})" 1 "${rc}"
    check_contains "rejection names the base URL" "base URL" "${err}"
done
rc=0
err=$("${KIMO}" launch kimi --provider vllm --model "bad id" --dry-run 2>&1) || rc=$?
check "a model id with a space is rejected" 1 "${rc}"
check_contains "rejection names the alias" "alias" "${err}"
rc=0
err=$(KIMO_VLLM_CTX=abc "${KIMO}" launch kimi --provider vllm --dry-run 2>&1) || rc=$?
check "a non-integer KIMO_VLLM_CTX is rejected at launch" 1 "${rc}"

echo "[3] vLLM is kimi-only, and selection does not follow stray keys"
rc=0
err=$("${KIMO}" launch grok --provider vllm --dry-run 2>&1) || rc=$?
check "grok is rejected" 1 "${rc}"
check_contains "the error names kimi" "kimi" "${err}"
dry=$(VLLM_API_KEY="vllm-test-key" OPENAI_API_KEY="ollama" "${KIMO}" launch kimi --dry-run 2>&1)
check_contains "a key alone stays on ollama" "provider: ollama" "${dry}"
check_not_contains "a key alone is not vllm" "provider: vllm" "${dry}"
dry=$("${KIMO}" launch kimi --model vllm --dry-run 2>&1)
check_contains "the bare name vllm is not a provider" "provider: ollama" "${dry}"
check_not_contains "bare name does not select vllm" "provider: vllm" "${dry}"
dry=$("${KIMO}" launch kimi --model vllm/my-model --dry-run)
check_contains "vllm/ prefix selects the provider" "provider: vllm" "${dry}"
check "prefix launch argv" "kimi -m vllm/my-model" "$(argv_of "${dry}")"
check_not_contains "prefix dry-run hides nothing secret" "vllm-test-key" "${dry}"

echo "[4] provider precedence and host selection"
"${KIMO}" config set cloud_provider vllm >/dev/null
check "config accepts vllm" vllm "$("${KIMO}" config get cloud_provider)"
dry=$("${KIMO}" launch kimi --dry-run)
check_contains "config selects vllm" "provider: vllm" "${dry}"
dry=$(KIMO_CLOUD_PROVIDER=ollama "${KIMO}" launch kimi --dry-run)
check_contains "KIMO_CLOUD_PROVIDER beats config" "provider: ollama" "${dry}"
dry=$(KIMO_CLOUD_PROVIDER=vllm "${KIMO}" launch kimi --provider ollama --dry-run)
check_contains "an explicit --provider ollama wins" "provider: ollama" "${dry}"
"${KIMO}" config unset cloud_provider >/dev/null
"${KIMO}" config set default_model served-from-config >/dev/null
dry=$("${KIMO}" launch kimi --provider vllm --dry-run)
check "a non-preset default_model is kept" "kimi -m vllm/served-from-config" "$(argv_of "${dry}")"
"${KIMO}" config unset default_model >/dev/null
dry=$(KIMO_VLLM_MODEL="vllm/from-env" "${KIMO}" launch kimi --provider vllm --dry-run)
check "KIMO_VLLM_MODEL supplies the id" "kimi -m vllm/from-env" "$(argv_of "${dry}")"
dry=$("${KIMO}" --host 127.0.0.1:9000 launch kimi --provider vllm --model m --dry-run)
check_contains "global --host is the vLLM base" "host   : http://127.0.0.1:9000/v1" "${dry}"
check "non-default host gets its own provider id" "kimi -m vllm-127-0-0-1-9000-v1/m" "$(argv_of "${dry}")"
dry=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:8000/v1" "${KIMO}" --host 127.0.0.1:9000 launch kimi --provider vllm --model m --dry-run)
check_contains "KIMO_VLLM_BASE_URL beats --host" "host   : http://127.0.0.1:8000/v1" "${dry}"
check "default base keeps the short provider id" "kimi -m vllm/m" "$(argv_of "${dry}")"
dry=$(VLLM_BASE_URL="http://127.0.0.1:7000" KIMO_VLLM_BASE_URL="http://127.0.0.1:8000/v1" \
    "${KIMO}" launch kimi --provider vllm --model m --dry-run)
check_contains "KIMO_VLLM_BASE_URL beats VLLM_BASE_URL" "host   : http://127.0.0.1:8000/v1" "${dry}"
harness_reset_stub_log
dry=$("${KIMO}" --host 10.0.0.5 launch kimi --provider vllm --model llama --dry-run)
check_contains "a bare host gets port 8000" "host   : http://10.0.0.5:8000/v1" "${dry}"
check_not_contains "a bare host does not get Ollama's port" "11434" "${dry}"
check "remote dry-run argv" "kimi -m vllm-10-0-0-5-8000-v1/llama" "$(argv_of "${dry}")"
check "dry-run does not probe that host" "" "$(harness_stub_calls curl)"
dry=$("${KIMO}" launch kimi --provider vllm --host 10.9.9.9 --dry-run)
check_contains "a --host after launch stays a kimi flag" "--host" "$(argv_of "${dry}")"
check_contains "passthrough --host is not the server" "10.9.9.9" "$(argv_of "${dry}")"
check_contains "the server stays the default" "host   : http://127.0.0.1:8000/v1" "${dry}"

echo "[5] live catalogue registration"
reset_kimi
reset_log
printf 'ok\n' >"${MODE_FILE}"
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "catalogue launch exits 0" 0 "${rc}"
check "launched alias" "${PID}/${LLAMA}" "$(flag_val "${CAPTURE}" -m)"
check "config path unsets KIMI_MODEL_NAME" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "config path unsets KIMI_MODEL_API_KEY" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "telemetry disabled" 1 "$(env_val "${CAPTURE}" KIMI_DISABLE_TELEMETRY)"
check "no auto update" 1 "$(env_val "${CAPTURE}" KIMI_CODE_NO_AUTO_UPDATE)"
check "headers timeout" 600000 "$(env_val "${CAPTURE}" KIMI_CODE_LLM_HEADERS_TIMEOUT_MS)"
check "OLLAMA_HOST is unset" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
check "OPENAI_BASE_URL is the /v1 base" "${BASE}" "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
check "OPENAI_API_BASE is not doubled" "${BASE}" "$(env_val "${CAPTURE}" OPENAI_API_BASE)"
check "placeholder OPENAI_API_KEY" EMPTY "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "probe sent no Authorization" "$(printf '/v1/models\t')" "$(tail -n1 "${LOG_FILE}")"
check "provider type" openai "$(py 'doc["providers"]["'"${PID}"'"]["type"]')"
check "provider base_url" "${BASE}" "$(py 'doc["providers"]["'"${PID}"'"]["base_url"]')"
check "no key stores EMPTY" EMPTY "$(py 'doc["providers"]["'"${PID}"'"].get("api_key")')"
check "no key does not store api_key_env" "" "$(py 'doc["providers"]["'"${PID}"'"].get("api_key_env", "")')"
check "default_model is the launched alias" "${PID}/${LLAMA}" "$(py 'doc["default_model"]')"
check "four served models are registered" 4 "$(py 'len(doc["models"])')"
check "llama capabilities" tool_use "$(caps_of "${PID}/${LLAMA}")"
check "llama context leaves template slack" 7936 "$(py 'doc["models"]["'"${PID}/${LLAMA}"'"]["max_context_size"]')"
check "llama max output fits the window" 2048 "$(py 'doc["models"]["'"${PID}/${LLAMA}"'"]["max_output_size"]')"
check "llama has no efforts" False "$(py '"support_efforts" in doc["models"]["'"${PID}/${LLAMA}"'"]')"
check "llama display name" "${LLAMA} (vllm)" "$(py 'doc["models"]["'"${PID}/${LLAMA}"'"]["display_name"]')"
check "R1 capabilities" "thinking,tool_use" "$(caps_of "${PID}/${R1}")"
check "R1 context leaves template slack" 16128 "$(py 'doc["models"]["'"${PID}/${R1}"'"]["max_context_size"]')"
check "reserve is an eighth of the smallest window" 224 "$(py 'doc["loop_control"]["reserved_context_size"]')"
check "R1 efforts" "low,medium,high" "$(py '"," .join(doc["models"]["'"${PID}/${R1}"'"]["support_efforts"])')"
check "R1 off effort" low "$(py 'doc["models"]["'"${PID}/${R1}"'"]["off_effort"]')"
check "R1 reasoning key" reasoning_content "$(py 'doc["models"]["'"${PID}/${R1}"'"]["reasoning_key"]')"
check "R1 default effort" high "$(py 'doc["models"]["'"${PID}/${R1}"'"]["default_effort"]')"
check "r100 is not treated as r1" tool_use "$(caps_of "${PID}/${R100}")"
check "r100 has no reasoning key" False "$(py '"reasoning_key" in doc["models"]["'"${PID}/${R100}"'"]')"
check "an r1- segment is thinking" "thinking,tool_use" "$(caps_of "${PID}/${R1D}")"
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "a second launch still exits 0" 0 "${rc}"
check "a second launch does not duplicate aliases" 4 "$(py 'len(doc["models"])')"
check_contains "launch lists the served models" "vLLM models at ${BASE}" "${live}"
check_contains "launch names the auto-selected model" "using vLLM model: ${LLAMA}" "${live}"

echo "[5b] endpoint discovery when no base is configured"
reset_kimi
reset_log
rc=0
# A live vLLM on :8000 must not satisfy this check. KIMO_VLLM_DEFAULT_BASE
# moves the first probe off that port without pinning the base, so discovery
# still walks KIMO_VLLM_BASE_URLS.
disc=$(KIMO_VLLM_DEFAULT_BASE="http://127.0.0.1:1/v1" \
    KIMO_VLLM_BASE_URLS="http://127.0.0.1:1/v1, ${BASE}" \
    "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "discovery launch exits 0" 0 "${rc}"
check_contains "discovery reports the found base" "found a vLLM server at ${BASE}" "${disc}"
check "discovery launches the served alias" "${PID}/${LLAMA}" "$(flag_val "${CAPTURE}" -m)"
check "discovery registers the fixture base" "${BASE}" "$(py 'doc["providers"]["'"${PID}"'"]["base_url"]')"
# An explicit base pins the endpoint; the fallback list must not override it.
rc=0
err=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:1/v1" KIMO_VLLM_BASE_URLS="${BASE}" \
    "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "an explicit base disables discovery" 1 "${rc}"
check_contains "the error lists the pinned base" "http://127.0.0.1:1/v1" "${err}"

echo "[5c] default fallback list and chat-model selection"
cand_fns="$(sed -n '/^vllm_normalize_base()/,/^}/p' "${KIMO}")"$'\n'"$(sed -n '/^vllm_candidate_bases()/,/^}/p' "${KIMO}")"
cands=$(bash -c "${cand_fns}; VLLM_BASE_URL_DEFAULT=http://127.0.0.1:8000/v1; vllm_candidate_bases")
check_contains "default fallback includes :8000" "http://127.0.0.1:8000/v1" "${cands}"
check_contains "default fallback includes the :18000 tunnel" "http://127.0.0.1:18000/v1" "${cands}"
check_contains "default fallback includes the GPU box" "http://192.168.1.104:8000/v1" "${cands}"
cands=$(KIMO_VLLM_BASE_URLS="10.0.0.9:9000, https://gpu.example:8443/v1" \
    bash -c "${cand_fns}; vllm_candidate_bases")
check_contains "KIMO_VLLM_BASE_URLS is normalized" "http://10.0.0.9:9000/v1" "${cands}"
check_contains "KIMO_VLLM_BASE_URLS keeps https" "https://gpu.example:8443/v1" "${cands}"
pick_fn="$(sed -n '/^vllm_pick_model()/,/^}/p' "${KIMO}")"
pick=$(bash -c "${pick_fn}; vllm_pick_model '{\"data\":[{\"id\":\"intfloat/e5-embed\"},{\"id\":\"org/Chat-7B\"}]}'")
check "an embedding id is skipped when a chat model is served" "org/Chat-7B" "${pick}"
pick=$(bash -c "${pick_fn}; vllm_pick_model '{\"data\":[{\"id\":\"intfloat/e5-embed\"}]}'")
check "an embedding-only server still yields an id" "intfloat/e5-embed" "${pick}"

echo "[6] context cap, effort fallback, capability override, register-all"
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model "${LLAMA}" --ctx 100 2>&1) || rc=$?
check "small --ctx exits 0" 0 "${rc}"
check "small --ctx is stored" 100 "$(py 'doc["models"]["'"${PID}/${LLAMA}"'"]["max_context_size"]')"
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model "${R1}" --ctx 999999 2>&1) || rc=$?
check "oversized --ctx still launches" 0 "${rc}"
check_contains "oversized --ctx is capped" "Capping to 16128" "${live}"
check "R1 context leaves room under the server window" 16128 "$(py 'doc["models"]["'"${PID}/${R1}"'"]["max_context_size"]')"
rc=0
live=$(KIMO_KIMI_EFFORT=max KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model "${R1}" 2>&1) || rc=$?
check "unknown effort still launches" 0 "${rc}"
check_contains "unknown effort warns" "not in" "${live}"
check "unknown effort falls back to high" high "$(py 'doc["models"]["'"${PID}/${R1}"'"]["default_effort"]')"
rc=0
live=$(KIMO_KIMI_EFFORT=high KIMO_VLLM_BASE_URL="${BASE}" \
    "${KIMO}" launch kimi --provider vllm --model qwen3.8-27b 2>&1) || rc=$?
check "qwen3.8 launch exits 0" 0 "${rc}"
check_contains "qwen3.8 maps high to medium" "using medium" "${live}"
check "qwen3.8 efforts omit high" "low,medium,xhigh" "$(py '"," .join(doc["models"]["'"${PID}/qwen3.8-27b"'"]["support_efforts"])')"
check "qwen3.8 default effort is medium" medium "$(py 'doc["models"]["'"${PID}/qwen3.8-27b"'"]["default_effort"]')"
rc=0
live=$(KIMO_KIMI_CAPABILITIES=thinking,tool_use KIMO_VLLM_BASE_URL="${BASE}" \
    "${KIMO}" launch kimi --provider vllm --model "${LLAMA}" 2>&1) || rc=$?
check "capability override launches" 0 "${rc}"
check "override marks the launched model thinking" "thinking,tool_use" "$(caps_of "${PID}/${LLAMA}")"
check "override does not mark r100 thinking" tool_use "$(caps_of "${PID}/${R100}")"
reset_kimi
rc=0
live=$(KIMO_KIMI_REGISTER_ALL=0 KIMO_VLLM_BASE_URL="${BASE}" \
    "${KIMO}" launch kimi --provider vllm --model "${LLAMA}" 2>&1) || rc=$?
check "register-all opt-out exits 0" 0 "${rc}"
check "only the launched model is registered" 1 "$(py 'len(doc["models"])')"
check "the launched alias is the one kept" "${LLAMA}" "$(py 'doc["models"]["'"${PID}/${LLAMA}"'"]["model"]')"

echo "[7] API key: name only, bearer on the probe, never in argv or dry-run"
reset_kimi
reset_log
KEY="vllm-test-key"
rc=0
dry=$(VLLM_API_KEY="${KEY}" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "dry-run with a key exits 0" 0 "${rc}"
check_contains "the key is masked" "<kept: real value, vLLM key>" "${dry}"
check_not_contains "dry-run never prints the key" "${KEY}" "${dry}"
check "dry-run with a key wrote no config" absent "$([[ -e "${KIMI_CFG}" ]] && echo present || echo absent)"
rc=0
live=$(VLLM_API_KEY="${KEY}" KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "keyed launch exits 0" 0 "${rc}"
check "config names VLLM_API_KEY" VLLM_API_KEY "$(py 'doc["providers"]["'"${PID}"'"].get("api_key_env", "")')"
check "config has no api_key" "" "$(py 'doc["providers"]["'"${PID}"'"].get("api_key", "")')"
check_not_contains "the key is not in config.toml" "${KEY}" "$(cat "${KIMI_CFG}")"
check_not_contains "the key is not in argv" "${KEY}" "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}")"
check "the child receives VLLM_API_KEY" "${KEY}" "$(env_val "${CAPTURE}" VLLM_API_KEY)"
check "probe sent the bearer" "$(printf '/v1/models\tBearer %s' "${KEY}")" "$(tail -n1 "${LOG_FILE}")"
rc=0
live=$(VLLM_API_KEY="${KEY}" KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "a second keyed launch keeps a single api_key_env" VLLM_API_KEY "$(py 'doc["providers"]["'"${PID}"'"].get("api_key_env", "")')"
check "a second keyed launch still has no api_key" "" "$(py 'doc["providers"]["'"${PID}"'"].get("api_key", "")')"

echo "[8] auth failure, empty catalogue, redirects, and the env channel"
reset_kimi
reset_log
printf '401\n' >"${MODE_FILE}"
rc=0
err=$(VLLM_API_KEY="${KEY}" KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model "${LLAMA}" 2>&1) || rc=$?
check "401 aborts" 1 "${rc}"
check_contains "401 names VLLM_API_KEY" "VLLM_API_KEY" "${err}"
check "401 writes no config" absent "$([[ -e "${KIMI_CFG}" ]] && echo present || echo absent)"
check "401 does not exec kimi" absent "$([[ -e "${CAPTURE}" ]] && echo present || echo absent)"
printf '302\n' >"${MODE_FILE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model foo 2>&1) || rc=$?
check "a redirect falls back when a model was named" 0 "${rc}"
check "redirect fallback has no -m" no "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
check "redirect fallback model" foo "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "redirect writes no config" absent "$([[ -e "${KIMI_CFG}" ]] && echo present || echo absent)"
printf 'empty\n' >"${MODE_FILE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model foo 2>&1) || rc=$?
check "an empty catalogue with --model uses the env channel" 0 "${rc}"
check "empty-catalogue model" foo "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "empty catalogue writes no config" absent "$([[ -e "${KIMI_CFG}" ]] && echo present || echo absent)"
printf 'ok\n' >"${MODE_FILE}"
rm -f "${CAPTURE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:1/v1" "${KIMO}" launch kimi --provider vllm --model foo 2>&1) || rc=$?
check "unreachable with --model exits 0" 0 "${rc}"
check_contains "unreachable warns about the env channel" "KIMI_MODEL_" "${err}"
check "env model name" foo "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "env provider type" openai "$(env_val "${CAPTURE}" KIMI_MODEL_PROVIDER_TYPE)"
check "env base url" "http://127.0.0.1:1/v1" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
check "env api key placeholder" EMPTY "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "env context default" 32768 "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check "env caps" tool_use "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "env reasoning key unset" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "env thinking effort unset" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check "env fallback has no -m" no "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
rm -f "${CAPTURE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:1/v1" VLLM_API_KEY="${KEY}" \
    "${KIMO}" launch kimi --provider vllm --model "${R1}" 2>&1) || rc=$?
check "unreachable reasoning id exits 0" 0 "${rc}"
check "unreachable reasoning key" reasoning_content "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "unreachable reasoning effort" high "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check "unreachable reasoning caps" "thinking,tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "unreachable forwards the vLLM key" "${KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
rm -f "${CAPTURE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:1/v1" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "unreachable without a model exits 1" 1 "${rc}"
check_contains "the error tells the user to start vLLM or pass --model" "--model" "${err}"
check "no kimi exec without a model" absent "$([[ -e "${CAPTURE}" ]] && echo present || echo absent)"
rc=0
err=$(VLLM_API_KEY=$'bad key' "${KIMO}" launch kimi --provider vllm --model foo 2>&1) || rc=$?
check "a key with whitespace is rejected" 1 "${rc}"
check_contains "whitespace rejection" "whitespace" "${err}"

echo "[9] remote scrub keeps only VLLM_API_KEY, and Ollama is not probed"
harness_reset_stub_log
rm -f "${CAPTURE}"
rc=0
live=$(OPENAI_API_KEY="sk-real" VLLM_API_KEY="vllm-secret" \
    KIMO_VLLM_BASE_URL="http://gpu.kimo-test.invalid:8000/v1" \
    "${KIMO}" launch kimi --provider vllm --model llama 2>&1) || rc=$?
check "remote env fallback exits 0" 0 "${rc}"
check "remote OPENAI_API_KEY is scrubbed" ollama "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "remote KIMI_MODEL_API_KEY is the vLLM key" vllm-secret "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "remote VLLM_API_KEY is kept" vllm-secret "$(env_val "${CAPTURE}" VLLM_API_KEY)"
check "remote base is unchanged" "http://gpu.kimo-test.invalid:8000/v1" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
check "remote fallback has no -m" no "$(has_flag "${CAPTURE}" -m && echo yes || echo no)"
check_not_contains "no Ollama tag probe" "/api/tags" "$(cat "${HARNESS_STUB_LOG}")"
check_contains "the blocked call is the vLLM models URL" "gpu.kimo-test.invalid:8000/v1/models" "$(cat "${HARNESS_STUB_LOG}")"
harness_reset_stub_log
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" --remote launch kimi --provider vllm --model "${LLAMA}" 2>&1) || rc=$?
check "remote flag still launches against vLLM" 0 "${rc}"
check "launched the fixture alias" "${PID}/${LLAMA}" "$(flag_val "${CAPTURE}" -m)"
check "no Ollama probe on --remote" "" "$(harness_stub_calls curl)"

echo "[10] a missing kimi binary is an error, not an ollama run"
harness_reset_stub_log
rc=0
miss=$(PATH="${HARNESS_STUB_DIR}:/usr/bin:/bin" "${KIMO}" launch kimi --provider vllm --model foo --dry-run 2>&1) || rc=$?
check "dry-run without kimi still exits 0" 0 "${rc}"
check_contains "dry-run says there is no ollama fallback" "does not fall back" "${miss}"
check_not_contains "dry-run argv is not an ollama command" "argv   : ollama" "${miss}"
harness_reset_stub_log
rc=0
miss=$(PATH="${HARNESS_STUB_DIR}:/usr/bin:/bin" KIMO_VLLM_BASE_URL="http://127.0.0.1:1/v1" \
    "${KIMO}" launch kimi --provider vllm --model foo 2>&1) || rc=$?
check "live launch without kimi exits 1" 1 "${rc}"
check_contains "the error tells the user to install kimi" "install kimi" "${miss}"
check_not_contains "live launch does not fall through to ollama" "Falling back to native" "${miss}"
check "ollama was not executed" "" "$(harness_stub_calls ollama)"

echo "[11] a proxy must not hide a loopback vLLM"
reset_kimi
reset_log
printf 'ok\n' >"${MODE_FILE}"
rc=0
live=$(http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=socks5h://127.0.0.1:9 \
    KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "proxy does not hide the loopback server" 0 "${rc}"
check "proxy launch still selects the served model" "${PID}/${LLAMA}" "$(flag_val "${CAPTURE}" -m)"
check_contains "proxy launch lists the fixture" "vLLM models at ${BASE}" "${live}"

echo "[12] API key file: loopback home file, explicit file, unsafe files ignored"
reset_kimi
reset_log
printf 'ok\n' >"${MODE_FILE}"
KEY="vllm-test-key"
KEYFILE="${HARNESS_ROOT}/home/vllm/api.key"
mkdir -p "${HARNESS_ROOT}/home/vllm"
printf '%s\n' "${KEY}" >"${KEYFILE}"
chmod 600 "${KEYFILE}"
unset VLLM_API_KEY || true
rc=0
dry=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "home key file dry-run exits 0" 0 "${rc}"
check_contains "home key file is masked" "<kept: real value, vLLM key>" "${dry}"
check_contains "home key file names its path" "vLLM API key from ${KEYFILE}" "${dry}"
check_not_contains "home key file is not printed" "${KEY}" "${dry}"
rc=0
live=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm 2>&1) || rc=$?
check "home key file launch exits 0" 0 "${rc}"
check "home key file reaches the child" "${KEY}" "$(env_val "${CAPTURE}" VLLM_API_KEY)"
check "home key file is the probe bearer" "$(printf '/v1/models\tBearer %s' "${KEY}")" "$(tail -n1 "${LOG_FILE}")"
check "home key file config names the env var" VLLM_API_KEY "$(py 'doc["providers"]["'"${PID}"'"].get("api_key_env", "")')"
check "home key file config has no api_key" "" "$(py 'doc["providers"]["'"${PID}"'"].get("api_key", "")')"
check_not_contains "home key file is not in config.toml" "${KEY}" "$(cat "${KIMI_CFG}")"
check_not_contains "home key file is not in the launch output" "${KEY}" "${live}"
rc=0
live=$(VLLM_API_KEY="from-env" KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model m 2>&1) || rc=$?
check "VLLM_API_KEY beats the home file" 0 "${rc}"
check "the child gets the env key, not the file" "from-env" "$(env_val "${CAPTURE}" VLLM_API_KEY)"
check "the probe bearer is the env key" "$(printf '/v1/models\tBearer %s' "from-env")" "$(tail -n1 "${LOG_FILE}")"
unset VLLM_API_KEY || true
rc=0
dry=$(KIMO_VLLM_BASE_URL="http://10.0.0.5:8000/v1" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "home key file is not used for a remote base" 0 "${rc}"
check_contains "remote base leaves VLLM_API_KEY unset" "VLLM_API_KEY <unset>" "${dry}"
check_not_contains "remote base does not print the home key" "${KEY}" "${dry}"
rc=0
dry=$(KIMO_VLLM_API_KEY_FILE="${KEYFILE}" KIMO_VLLM_BASE_URL="http://10.0.0.5:8000/v1" \
    "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "explicit key file works off-box" 0 "${rc}"
check_contains "explicit key file is masked" "<kept: real value, vLLM key>" "${dry}"
check_contains "explicit key file names its path" "vLLM API key from ${KEYFILE}" "${dry}"
check_not_contains "explicit key file is not printed" "${KEY}" "${dry}"
chmod 666 "${KEYFILE}"
rc=0
dry=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "other-writable home file is ignored" 0 "${rc}"
check_contains "ignored home file leaves the key unset" "VLLM_API_KEY <unset>" "${dry}"
check_not_contains "ignored home file is not printed" "${KEY}" "${dry}"
chmod 600 "${KEYFILE}"
printf 'bad key\n' >"${KEYFILE}"
rc=0
err=$(KIMO_VLLM_BASE_URL="${BASE}" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "a key file with whitespace is rejected" 1 "${rc}"
check_contains "whitespace file rejection names the file" "${KEYFILE}" "${err}"
check_not_contains "whitespace file contents are not printed" "bad key" "${err}"
rc=0
err=$(KIMO_VLLM_API_KEY_FILE="${HARNESS_ROOT}/no-such-vllm-key" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "a missing explicit key file is rejected" 1 "${rc}"
check_contains "missing key file names the variable" "KIMO_VLLM_API_KEY_FILE" "${err}"
printf '%s\n' "${KEY}" >"${KEYFILE}"
chmod 600 "${KEYFILE}"
ln -s "${KEYFILE}" "${HARNESS_ROOT}/vllm-key.link"
rc=0
err=$(KIMO_VLLM_API_KEY_FILE="${HARNESS_ROOT}/vllm-key.link" "${KIMO}" launch kimi --provider vllm --model m --dry-run 2>&1) || rc=$?
check "a symlink key file is rejected" 1 "${rc}"
check_contains "symlink rejection says symlink" "symlink" "${err}"
check_not_contains "symlink rejection does not print the key" "${KEY}" "${err}"
rm -rf "${HARNESS_ROOT}/home/vllm" "${HARNESS_ROOT}/vllm-key.link"
unset VLLM_API_KEY || true
printf 'ok\n' >"${MODE_FILE}"

echo
harness_summary "vllm-smoke"
