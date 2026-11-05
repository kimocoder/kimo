#!/usr/bin/env bash
# Headless tests for `kimo launch claude --provider`.
#
# Claude Code speaks Anthropic /v1/messages. Hosted backends that do not are
# reached through lib/kimo-anthropic-proxy.py. This file checks the dry-run
# contract (no proxy is started) and the proxy's translation against a local
# upstream (no network).
#
# Usage: tests/claude_providers_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
PROXY="${ROOT_DIR}/lib/kimo-anthropic-proxy.py"

XAI_KEY="xai-fixture-key"
OPENAI_KEY="sk-fixture-openai-key"
ANT_KEY="sk-ant-fixture-key"
QW_KEY="sk-qwen-fixture-key"
GM_KEY="AIzaSyFixtureGeminiKey0123456789"
CODEX_TOKEN="codex-oauth-fixture"

echo "[*] [1] Dry-run routing"
rc=0
dry=$(XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch claude --provider xai --dry-run 2>/dev/null) || rc=$?
check "xai dry-run succeeds" 0 "${rc}"
check_contains "xai provider" "provider: xai" "${dry}"
check_contains "xai responses wire" "anthropic -> responses (https://api.x.ai/v1)" "${dry}"
check_contains "xai default model" "model  : grok-4.7" "${dry}"
check_contains "xai argv" "claude --model grok-4.7" "${dry}"
check_contains "xai key is masked" "secret : XAI_API_KEY <kept: real value, xAI key>" "${dry}"
check_not_contains "dry-run never prints the xai key" "${XAI_KEY}" "${dry}"

dry=$(XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch claude --provider grok --model xai/grok-3 --dry-run)
check_contains "grok is an alias of xai" "provider: xai" "${dry}"
check_contains "xai/ prefix is stripped" "model  : grok-3" "${dry}"

# A grok-login JWT is not an api.x.ai key. The CLI chat proxy requires
# Chat Completions plus X-XAI-Token-Auth, and 401s a Responses bearer.
JWT_KEY="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyIn0.mock"
dry=$(XAI_API_KEY="${JWT_KEY}" "${KIMO}" launch claude --provider xai --model grok-4.7 --dry-run)
check_contains "grok login uses the CLI proxy" "host   : https://cli-chat-proxy.grok.com/v1" "${dry}"
check_contains "grok login uses chat completions" "anthropic -> chat (https://cli-chat-proxy.grok.com/v1)" "${dry}"
check_not_contains "dry-run never prints the session token" "${JWT_KEY}" "${dry}"
grok_headers="$(python3 - "${ROOT_DIR}/lib/kimo-anthropic-proxy.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("anthropic_proxy", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.grok_cli_host("https://cli-chat-proxy.grok.com/v1")
assert not mod.grok_cli_host("https://api.x.ai/v1")
headers = mod.grok_session_headers("https://cli-chat-proxy.grok.com/v1", {"model": "grok-4.7"})
assert headers["X-XAI-Token-Auth"] == "xai-grok-cli", headers
assert headers["x-grok-model-override"] == "grok-4.7", headers
assert mod.grok_session_headers("https://api.x.ai/v1", {"model": "grok-4.7"}) == {}
print("grok-headers-ok")
PY
)"
check "CLI proxy host is distinguished from api.x.ai" "grok-headers-ok" "${grok_headers}"

rc=0
missing=$("${KIMO}" launch claude --provider xai --dry-run 2>&1) || rc=$?
check "a missing xai key fails" 1 "${rc}"
check_contains "the error names XAI_API_KEY" "XAI_API_KEY" "${missing}"

rc=0
closed=$("${KIMO}" launch kimi --provider xai --dry-run 2>&1) || rc=$?
check "kimi still has no xai branch" 1 "${rc}"
check_contains "the rejection names claude" "supports codex claude" "${closed}"

dry=$(QWENCLOUD_API_KEY="${QW_KEY}" "${KIMO}" launch claude --provider qwencloud --dry-run)
check_contains "qwencloud chat wire" "anthropic -> chat (https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1)" "${dry}"
argv="$(printf '%s\n' "${dry}" | sed -n 's/^  argv   : //p')"
check_contains "qwencloud argv names the model" "qwen3.8-max" "${argv}"
check_contains "qwencloud argv marks the 1m window" "1m" "${argv}"
check_not_contains "dry-run never prints the qwen key" "${QW_KEY}" "${dry}"

dry=$(ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" launch claude --provider anthropic --dry-run)
check_contains "anthropic is native" "wire   : anthropic native (https://api.anthropic.com)" "${dry}"
check_contains "anthropic host is the official API" "host   : https://api.anthropic.com" "${dry}"
argv="$(printf '%s\n' "${dry}" | sed -n 's/^  argv   : //p')"
check_contains "anthropic argv names the model" "claude-opus-5-5" "${argv}"
check_contains "anthropic argv marks the 1m window" "1m" "${argv}"
check_contains "anthropic key is masked" "secret : ANTHROPIC_API_KEY <kept: real value, Anthropic key>" "${dry}"
check_not_contains "dry-run never prints the anthropic key" "${ANT_KEY}" "${dry}"
check_not_contains "native dry-run does not export a base URL" "env    : ANTHROPIC_BASE_URL=" "${dry}"

dry=$(ANTHROPIC_API_KEY="${ANT_KEY}" "${KIMO}" launch claude --provider claude --model anthropic/claude-sonnet-5-5 --dry-run)
check_contains "provider claude aliases anthropic" "provider: anthropic" "${dry}"
check_contains "anthropic/ prefix is stripped" "model  : claude-sonnet-5-5" "${dry}"

dry=$(GEMINI_API_KEY="${GM_KEY}" "${KIMO}" launch claude --provider gemini --dry-run)
check_contains "gemini chat wire" "anthropic -> chat (https://generativelanguage.googleapis.com/v1beta/openai)" "${dry}"
check_contains "gemini default model" "model  : gemini-2.5-flash" "${dry}"
check_not_contains "gemini does not hit the Codex Responses guard" "does not support the OpenAI Responses API" "${dry}"

rc=0
# A live codex launch still refuses the official Gemini host. Claude must not.
err_gm=$(GEMINI_API_KEY="${GM_KEY}" "${KIMO}" launch codex --provider gemini 2>&1) || rc=$?
check "codex gemini guard is unchanged" 1 "${rc}"
check_contains "the codex guard still names Responses" "does not support the OpenAI Responses API" "${err_gm}"

mkdir -p "${HOME}/.codex"
cat > "${HOME}/.codex/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-6.1-sol","visibility":"list","context_window":272000}]}
JSON
dry=$(OPENAI_API_KEY="${OPENAI_KEY}" "${KIMO}" launch claude --provider openai --dry-run)
check_contains "openai uses the catalog model" "model  : gpt-6.1-sol" "${dry}"
check_contains "openai responses wire" "anthropic -> responses (https://api.openai.com/v1)" "${dry}"
check_not_contains "dry-run never prints the openai key" "${OPENAI_KEY}" "${dry}"

dry=$(OPENAI_API_KEY="${OPENAI_KEY}" "${KIMO}" launch claude --provider openai --model openai/gpt-explicit --dry-run)
check_contains "openai/ prefix is stripped" "model  : gpt-explicit" "${dry}"

dry=$(CODEX_AUTH_TOKEN="${CODEX_TOKEN}" "${KIMO}" launch claude --provider codex --model codex/gpt-6.1-sol --dry-run)
check_contains "codex provider" "provider: codex" "${dry}"
check_contains "codex responses wire" "anthropic -> responses (https://chatgpt.com/backend-api/codex)" "${dry}"
check_contains "codex model prefix stripped" "model  : gpt-6.1-sol" "${dry}"
check_not_contains "dry-run never prints the codex token" "${CODEX_TOKEN}" "${dry}"

dry=$(KIMO_VLLM_BASE_URL="http://127.0.0.1:8000/v1" "${KIMO}" launch claude --provider vllm --model llama --dry-run)
check_contains "vllm chat wire" "anthropic -> chat (http://127.0.0.1:8000/v1)" "${dry}"
check_contains "vllm argv is claude" "claude --model llama" "${dry}"

rc=0
no_catalog_home="${HARNESS_ROOT}/empty-codex"
mkdir -p "${no_catalog_home}"
err=$(CODEX_HOME="${no_catalog_home}" OPENAI_API_KEY="${OPENAI_KEY}" "${KIMO}" launch claude --provider openai --dry-run 2>&1) || rc=$?
check "openai without a catalog or --model fails" 1 "${rc}"
check_contains "the error tells the user to pass --model" "--model" "${err}"

echo "[*] [2] Live launch points Claude at the proxy, not the upstream key"
FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/claude-call.txt"
mkdir -p "${FAKE_BIN}"
export CLAUDE_PROVIDERS_CAPTURE="${CAPTURE}"
cat > "${FAKE_BIN}/claude" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in ANTHROPIC_BASE_URL ANTHROPIC_API_BASE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
        ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL XAI_API_KEY CLAUDE_CODE_MAX_CONTEXT_TOKENS; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${CLAUDE_PROVIDERS_CAPTURE:?}"
exit 0
SH
chmod +x "${FAKE_BIN}/claude"
rc=0
PATH="${FAKE_BIN}:${PATH}" XAI_API_KEY="${XAI_KEY}" "${KIMO}" launch claude --provider xai --model grok-4.7 >/dev/null || rc=$?
check "live xai launch execs claude" 0 "${rc}"
check "live model flag" "grok-4.7" "$(flag_val "${CAPTURE}" --model)"
base="$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
check "live base is loopback" "http://127.0.0.1:" "${base:0:17}"
check "live token is not the xai key" "different" "$([[ "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)" != "${XAI_KEY}" && -n "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)" ]] && echo different || echo same)"
check "live ANTHROPIC_API_KEY is unset" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "live haiku tier stays on the launched model" "grok-4.7" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
check "live keeps the upstream key for the proxy" "${XAI_KEY}" "$(env_val "${CAPTURE}" XAI_API_KEY)"
check "live context window" "500000" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"

echo "[*] [3] Messages proxy translation"
UP_PORT_FILE="${HARNESS_ROOT}/up-port"
UP_BODY="${HARNESS_ROOT}/up-body.json"
UP_META="${HARNESS_ROOT}/up-meta.txt"
UP_HITS="${HARNESS_ROOT}/up-hits"
printf '0\n' > "${UP_HITS}"
python3 - "${UP_PORT_FILE}" "${UP_BODY}" "${UP_META}" "${UP_HITS}" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port_file, body_file, meta_file, hits_file = sys.argv[1:5]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n)
        open(body_file, "wb").write(raw)
        open(meta_file, "w", encoding="utf-8").write("\n".join([
            self.path,
            self.headers.get("Authorization") or "",
            self.headers.get("x-goog-api-key") or "",
            self.headers.get("Chatgpt-Account-Id") or "",
            self.headers.get("X-Grok-Client-Version") or "",
        ]))
        hits = int(open(hits_file, encoding="utf-8").read().strip() or "0") + 1
        open(hits_file, "w", encoding="utf-8").write(str(hits))
        auth = self.headers.get("Authorization") or ""
        if auth == "Bearer reject-me":
            msg = b'{"error":{"message":"bad key"}}'
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return
        payload = json.loads(raw.decode())
        if self.path.endswith("/responses"):
            sse = (
                'data: {"type":"response.output_text.delta","delta":"PONG"}\n\n'
                'data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_9","name":"Bash","arguments":""}}\n\n'
                'data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\\"command\\":\\"ls\\"}"}\n\n'
                'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":4}}}\n\n'
            ).encode()
        elif payload.get("stream") is False:
            sse = json.dumps({
                "choices": [{
                    "message": {"role": "assistant", "content": "PONG", "reasoning_content": "think"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 2, "completion_tokens": 1},
            }).encode()
        else:
            sse = (
                'data: {"choices":[{"index":0,"delta":{"reasoning_content":"think"},"finish_reason":null}]}\n\n'
                'data: {"choices":[{"index":0,"delta":{"content":"PONG"},"finish_reason":null}]}\n\n'
                'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"Bash","arguments":""}}]},"finish_reason":null}]}\n\n'
                'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"ls\\"}"}}]},"finish_reason":"tool_calls"}]}\n\n'
                'data: [DONE]\n\n'
            ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if payload.get("stream") is not False and not self.path.endswith("/responses") or self.path.endswith("/responses") else "application/json")
        self.send_header("Content-Length", str(len(sse)))
        self.end_headers()
        self.wfile.write(sse)

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w", encoding="utf-8").write(str(server.server_address[1]))
server.serve_forever()
PY
UP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "${UP_PORT_FILE}" ]] && break
    sleep 0.05
done
UP_PORT="$(tr -cd '0-9' <"${UP_PORT_FILE}")"
check "upstream fixture started" "yes" "$([[ -n "${UP_PORT}" ]] && echo yes || echo no)"

CLIENT_TOKEN="client-token-abc"
PORT_FILE="${HARNESS_ROOT}/proxy-port"
UPSTREAM_KEY="${XAI_KEY}" \
KIMO_ANTHROPIC_PROXY_CLIENT="${CLIENT_TOKEN}" \
    python3 "${PROXY}" --upstream "http://127.0.0.1:${UP_PORT}" --wire chat --env-key UPSTREAM_KEY \
    --provider xai --port-file "${PORT_FILE}" --exit-with-pid "$$" >/dev/null 2>&1 &
PROXY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "${PORT_FILE}" ]] && break
    sleep 0.05
done
PROXY_PORT="$(tr -cd '0-9' <"${PORT_FILE}")"
REQ='{"model":"grok-4.7[1m]","max_tokens":32,"stream":true,"system":"be brief","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file"}]}],"tools":[{"name":"Bash","description":"run","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}]}'
sse="$(curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" -H "x-api-key: ${CLIENT_TOKEN}" -H 'Content-Type: application/json' -d "${REQ}")"
check_contains "sse has the text" "PONG" "${sse}"
check_contains "sse has the thinking" "think" "${sse}"
check_contains "sse has the tool name" "Bash" "${sse}"
check_contains "sse stop is tool_use" "tool_use" "${sse}"
chat_ok="$(python3 - "${UP_BODY}" "${UP_META}" "${XAI_KEY}" <<'PY'
import json, sys
body, meta, key = sys.argv[1:]
payload = json.load(open(body, encoding="utf-8"))
lines = open(meta, encoding="utf-8").read().splitlines()
lines += [""] * (5 - len(lines))
path, auth, goog, account, grok = lines[:5]
assert path.endswith("/chat/completions"), path
assert payload["model"] == "grok-4.7", payload["model"]
assert payload["messages"][0] == {"role": "system", "content": "be brief"}, payload["messages"][0]
assert payload["messages"][2]["tool_calls"][0]["function"]["name"] == "Bash"
assert payload["messages"][3]["role"] == "tool"
assert payload["tools"][0]["function"]["name"] == "Bash"
assert auth == f"Bearer {key}", auth
assert grok == "1.0.70", grok
assert "client-token-abc" not in auth
print("chat-ok")
PY
)"
check "chat translation" "chat-ok" "${chat_ok}"

before="$(cat "${UP_HITS}")"
bad_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" -H 'x-api-key: nope' -H 'Content-Type: application/json' -d '{"model":"m","max_tokens":1,"messages":[]}')"
check "a bad client token is rejected" "401" "${bad_code}"
check "a bad client token does not call upstream" "${before}" "$(cat "${UP_HITS}")"

count="$(curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages/count_tokens" -H "x-api-key: ${CLIENT_TOKEN}" -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"hello"}]}')"
check "count_tokens returns a positive estimate" "yes" "$(python3 -c 'import json,sys; print("yes" if json.loads(sys.argv[1])["input_tokens"] > 0 else "no")' "${count}")"

plain="$(curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" -H "Authorization: Bearer ${CLIENT_TOKEN}" -H 'Content-Type: application/json' -d '{"model":"grok-4.7","max_tokens":8,"stream":false,"messages":[{"role":"user","content":"hi"}]}')"
check_contains "non-stream text" "PONG" "${plain}"
check_contains "non-stream thinking" "think" "${plain}"

# Upstream 401 becomes an Anthropic authentication_error and the key is redacted.
kill "${PROXY_PID}" 2>/dev/null || true
wait "${PROXY_PID}" 2>/dev/null || true
PORT_FILE="${HARNESS_ROOT}/proxy-port-2"
UPSTREAM_KEY="reject-me" \
KIMO_ANTHROPIC_PROXY_CLIENT="${CLIENT_TOKEN}" \
    python3 "${PROXY}" --upstream "http://127.0.0.1:${UP_PORT}" --wire chat --env-key UPSTREAM_KEY \
    --provider xai --port-file "${PORT_FILE}" --exit-with-pid "$$" >/dev/null 2>&1 &
PROXY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "${PORT_FILE}" ]] && break
    sleep 0.05
done
PROXY_PORT="$(tr -cd '0-9' <"${PORT_FILE}")"
err="$(curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" -H "x-api-key: ${CLIENT_TOKEN}" -H 'Content-Type: application/json' -d '{"model":"m","max_tokens":4,"stream":false,"messages":[{"role":"user","content":"hi"}]}')"
check_contains "upstream 401 is an authentication_error" "authentication_error" "${err}"
check_contains "upstream message is forwarded" "bad key" "${err}"
check_not_contains "the upstream key is not echoed" "reject-me" "${err}"
kill "${PROXY_PID}" 2>/dev/null || true
wait "${PROXY_PID}" 2>/dev/null || true

# Responses wire: model suffix stripped, store disabled, account id forwarded.
PORT_FILE="${HARNESS_ROOT}/proxy-port-3"
HEADER="$(printf '%s' '{"alg":"none"}' | base64 | tr -d '\n=' | tr '/+' '_-')"
PAYLOAD="$(printf '%s' '{"https://api.openai.com/auth":{"chatgpt_account_id":"acc-123"}}' | base64 | tr -d '\n=' | tr '/+' '_-')"
CODEX_JWT="${HEADER}.${PAYLOAD}.sig"
UPSTREAM_KEY="${CODEX_JWT}" \
KIMO_ANTHROPIC_PROXY_CLIENT="${CLIENT_TOKEN}" \
    python3 "${PROXY}" --upstream "http://127.0.0.1:${UP_PORT}" --wire responses --env-key UPSTREAM_KEY \
    --provider codex --port-file "${PORT_FILE}" --exit-with-pid "$$" >/dev/null 2>&1 &
PROXY_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "${PORT_FILE}" ]] && break
    sleep 0.05
done
PROXY_PORT="$(tr -cd '0-9' <"${PORT_FILE}")"
sse="$(curl -sS -m 5 -X POST "http://127.0.0.1:${PROXY_PORT}/v1/messages" -H "x-api-key: ${CLIENT_TOKEN}" -H 'Content-Type: application/json' -d '{"model":"gpt-6.1-sol[1m]","max_tokens":16,"stream":true,"system":"sys","messages":[{"role":"user","content":"hi"}]}')"
check_contains "responses sse text" "PONG" "${sse}"
check_contains "responses sse tool" "Bash" "${sse}"
responses_ok="$(python3 - "${UP_BODY}" "${UP_META}" <<'PY'
import json, sys
body, meta = sys.argv[1:]
payload = json.load(open(body, encoding="utf-8"))
lines = open(meta, encoding="utf-8").read().splitlines()
lines += [""] * (5 - len(lines))
path, auth, goog, account, grok = lines[:5]
assert path.endswith("/responses"), path
assert payload["model"] == "gpt-6.1-sol", payload["model"]
assert payload["store"] is False, payload["store"]
assert payload["instructions"] == "sys", payload
assert payload["max_output_tokens"] == 16, payload
assert account == "acc-123", account
assert auth.startswith("Bearer "), auth
print("responses-ok")
PY
)"
check "responses translation" "responses-ok" "${responses_ok}"

kill "${PROXY_PID}" "${UP_PID}" 2>/dev/null || true
wait "${PROXY_PID}" "${UP_PID}" 2>/dev/null || true

echo
harness_summary "claude_providers_test"
