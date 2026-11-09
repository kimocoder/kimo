#!/usr/bin/env bash
# Headless smoke tests for 'kimo launch claude --provider ollama-cloud'.
#
# A fake claude/kimi records argv and env. No network call and no TUI.
# The key must reach the child as a bearer token and must not appear in
# argv or in --dry-run output. ANTHROPIC_API_KEY stays empty so Claude Code
# does not send x-api-key, which ollama.com rejects on its own.

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

WORK="$(mktemp -d)"
FAKE_DIR="${WORK}/bin"
CAPTURE="${WORK}/call.txt"
mkdir -p "${FAKE_DIR}"
export OC_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/claude" <<'FAKE'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-<unset>}"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-<unset>}"
    printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}"
    printf 'CLAUDE_CODE_SUBAGENT_MODEL=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}"
    printf 'CLAUDE_CODE_MAX_CONTEXT_TOKENS=%s\n' "${CLAUDE_CODE_MAX_CONTEXT_TOKENS-<unset>}"
    printf 'CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=%s\n' "${CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST-<unset>}"
    printf 'OLLAMA_HOST=%s\n' "${OLLAMA_HOST-<unset>}"
    printf 'OLLAMA_API_KEY=%s\n' "${OLLAMA_API_KEY-<unset>}"
} > "${OC_SMOKE_OUT:?}"
exit 0
FAKE

cat > "${FAKE_DIR}/kimi" <<'FAKE'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'KIMI_MODEL_NAME=%s\n' "${KIMI_MODEL_NAME-<unset>}"
    printf 'KIMI_MODEL_PROVIDER_TYPE=%s\n' "${KIMI_MODEL_PROVIDER_TYPE-<unset>}"
    printf 'KIMI_MODEL_BASE_URL=%s\n' "${KIMI_MODEL_BASE_URL-<unset>}"
    printf 'KIMI_MODEL_API_KEY=%s\n' "${KIMI_MODEL_API_KEY-<unset>}"
    printf 'KIMI_MODEL_MAX_CONTEXT_SIZE=%s\n' "${KIMI_MODEL_MAX_CONTEXT_SIZE-<unset>}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-<unset>}"
    printf 'OLLAMA_HOST=%s\n' "${OLLAMA_HOST-<unset>}"
} > "${OC_SMOKE_OUT:?}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/claude" "${FAKE_DIR}/kimi"
export PATH="${FAKE_DIR}:${PATH}"

KEY="oc_TEST_SENTINEL_do_not_leak"
ORIGIN="https://ollama.com"
unset OLLAMA_API_KEY || true

launch_out() {
    rm -f "${CAPTURE}"
    LAUNCH_OUT="$("${KIMO}" launch "$@" 2>&1)" && LAUNCH_RC=0 || LAUNCH_RC=$?
}

echo "[1] claude routes at ollama.com with a bearer token"
launch_out claude --provider ollama-cloud
OLLAMA_API_KEY="${KEY}" launch_out claude --provider ollama-cloud
check "claude launch exits 0" 0 "${LAUNCH_RC}"
check "claude argv is the hosted id" "--model beam" "$(awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -)"
proxy_ok="$(python3 - "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)" "${KEY}" "${ORIGIN}" <<'PY'
import re, sys
base, token, key, origin = sys.argv[1:]
assert re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", base), base
assert origin not in base
assert token and token != key and key not in token
print("proxy-ok")
PY
)"
check "claude talks to the local messages proxy, not with the cloud key" "proxy-ok" "${proxy_ok}"
check "x-api-key stays empty" "" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
check "main model is the hosted id" "beam" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
check "haiku tier stays on the cloud model" "beam" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
check "sonnet tier stays on the cloud model" "beam" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
check "opus tier stays on the cloud model" "beam" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
check "subagents stay on the cloud model" "beam" "$(env_val "${CAPTURE}" CLAUDE_CODE_SUBAGENT_MODEL)"
check "context window stays the 1M fallback when the catalog is unreachable" "1000000" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
check "claude is marked provider-managed" "1" "$(env_val "${CAPTURE}" CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST)"
check "OLLAMA_HOST is not set" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
check_not_contains "launch output does not print the key" "${KEY}" "${LAUNCH_OUT}"
check_not_contains "launch output does not use a [1m] suffix" "beam[1m]" "${LAUNCH_OUT}"
check_contains "launch output names Ollama Cloud" "Ollama Cloud" "${LAUNCH_OUT}"
check_contains "launch output reports the fallback picker row" "1 model in /model" "${LAUNCH_OUT}"
picker_ok="$(python3 - "${HOME}/.claude/settings.json" "${KEY}" <<'PY'
import json, os, stat, sys
path, key = sys.argv[1], sys.argv[2]
assert os.path.isfile(path), path
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
text = open(path, encoding="utf-8").read()
assert key not in text
assert "beam[1m]" not in text
doc = json.loads(text)
assert "availableModels" not in doc
assert "env" not in doc
assert doc["modelPicker"]["replaceBuiltInOptions"] is False
opts = doc["modelPicker"]["options"]
assert [opt["model"] for opt in opts] == ["beam"], opts
row = opts[0]
assert row["label"] == "beam"
assert row["kimo"] == "kimo:ollama-cloud"
assert row["behavesAs"] == "claude-opus-4-8"
assert "1000000 ctx" in row["description"]
print("picker-ok")
PY
)"
check "unreachable catalog still writes a beam picker row" "picker-ok" "${picker_ok}"

echo "[2] --model and --ctx"
OLLAMA_API_KEY="${KEY}" launch_out claude --provider ollama-cloud --model gemma4:31b --ctx 65536
check "explicit model launch exits 0" 0 "${LAUNCH_RC}"
check "explicit model reaches claude" "--model gemma4:31b" "$(awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -)"
check "explicit context is exported" "65536" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
check "explicit model is not given a [1m] suffix" "gemma4:31b" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
gemma_ok="$(python3 - "${HOME}/.claude/settings.json" <<'PY'
import json, sys
opts = json.load(open(sys.argv[1], encoding="utf-8"))["modelPicker"]["options"]
models = [opt["model"] for opt in opts]
assert models[0] == "gemma4:31b", models
assert "beam" in models, models
row = opts[0]
assert row["kimo"] == "kimo:ollama-cloud"
assert row["behavesAs"] == "claude-haiku-4-5"
assert "65536 ctx" in row["description"]
print("gemma-ok")
PY
)"
check "offline --ctx row uses haiku and keeps the earlier beam row" "gemma-ok" "${gemma_ok}"

echo "[3] dry-run masks the key and does not exec"
rm -f "${CAPTURE}"
DRY_CFG="${WORK}/dry-claude"
mkdir -p "${DRY_CFG}"
dry=$(OLLAMA_API_KEY="${KEY}" CLAUDE_CONFIG_DIR="${DRY_CFG}" "${KIMO}" launch claude --provider ollama-cloud --dry-run 2>&1)
check_contains "dry-run names the provider" "provider: ollama-cloud" "${dry}"
check_contains "dry-run shows the origin" "ANTHROPIC_BASE_URL=https://ollama.com" "${dry}"
check_contains "dry-run keeps the bearer" "<kept: real value, Ollama Cloud key>" "${dry}"
check_contains "dry-run leaves x-api-key empty" "empty (Ollama Cloud uses the bearer token)" "${dry}"
check_contains "dry-run shows the fallback context" "context: 1000000 tokens" "${dry}"
check_contains "dry-run marks the provider host-managed" "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=1" "${dry}"
check_contains "dry-run mentions the /model picker" "/model picker" "${dry}"
check_not_contains "dry-run does not print the key" "${KEY}" "${dry}"
check_not_contains "dry-run argv has no [1m] suffix" "beam[1m]" "${dry}"
argv_line="$(printf '%s\n' "${dry}" | sed -n 's/^  argv   : //p')"
check "dry-run argv is the hosted id" "claude --model beam" "${argv_line}"
if [[ -f "${CAPTURE}" ]]; then
    bad "dry-run exec'd claude"
else
    ok "dry-run did not exec claude"
fi
if [[ -e "${DRY_CFG}/settings.json" ]]; then
    bad "dry-run wrote settings.json"
else
    ok "dry-run did not write settings.json"
fi

echo "[4] failures and kimi"
rc=0
err=$(env -u OLLAMA_API_KEY "${KIMO}" launch claude --provider ollama-cloud 2>&1) || rc=$?
check "a missing key is rejected" 1 "${rc}"
check_contains "the missing-key error names the variable" "OLLAMA_API_KEY" "${err}"
rc=0
err=$(OLLAMA_API_KEY="${KEY}" "${KIMO}" launch qwen --provider ollama-cloud 2>&1) || rc=$?
check "qwen is not wired" 1 "${rc}"
check_contains "the rejection names claude and kimi" "claude kimi" "${err}"
rc=0
err=$(OLLAMA_API_KEY="${KEY}" "${KIMO}" launch claude --provider ollama-cloud --model 'bad model' 2>&1) || rc=$?
check "a model id with a space is rejected" 1 "${rc}"

OLLAMA_API_KEY="${KEY}" launch_out kimi --provider ollama-cloud --model gemma4:31b
check "kimi launch exits 0" 0 "${LAUNCH_RC}"
check "kimi uses the OpenAI cloud base" "https://ollama.com/v1" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
check "kimi model is the hosted id" "gemma4:31b" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "kimi receives the key" "${KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
check "kimi does not point at a local daemon" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
check_not_contains "kimi launch output does not print the key" "${KEY}" "${LAUNCH_OUT}"

echo "[5] launch claude with no --provider uses Ollama Cloud and beam"
rm -f "${CAPTURE}"
default_out=$(OLLAMA_API_KEY="${KEY}" "${KIMO}" launch claude 2>&1) || default_rc=$?
default_rc=${default_rc:-0}
check "default claude launch exits 0" 0 "${default_rc}"
check "default argv is beam" "--model beam" "$(awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -)"
default_proxy="$(python3 - "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)" "${ORIGIN}" <<'PY'
import re, sys
base, origin = sys.argv[1:]
assert re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", base), base
assert origin not in base
print("default-proxy-ok")
PY
)"
check "default claude launch uses the messages proxy" "default-proxy-ok" "${default_proxy}"
check_not_contains "default launch does not print the key" "${KEY}" "${default_out}"

echo "[6] config"
"${KIMO}" config set cloud_provider ollama-cloud >/dev/null
check "config accepts ollama-cloud" "ollama-cloud" "$("${KIMO}" config get cloud_provider)"
dry=$(OLLAMA_API_KEY="${KEY}" "${KIMO}" launch claude --provider ollama --dry-run 2>&1)
check_contains "an explicit ollama provider wins" "provider: ollama" "${dry}"
"${KIMO}" config unset cloud_provider >/dev/null
rc=0
err=$("${KIMO}" config set cloud_provider bogus 2>&1) || rc=$?
check "a bogus provider is rejected" 1 "${rc}"

echo "[7] a loopback catalog is written into the /model picker"
CATALOG_PORT_FILE="${WORK}/catalog.port"
CATALOG_AUTH="${WORK}/catalog.auth"
: >"${CATALOG_AUTH}"
cat > "${WORK}/catalog.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AUTH = sys.argv[2]
MODELS = {
    "beam": {
        "ctx": 1048576,
        "info": {"beam.context_length": 1048576},
        "caps": ["completion", "thinking", "tools"],
    },
    "gemma4:31b": {
        "ctx": 262144,
        "info": {"unrelated.context_length": 9999999, "gemma4.context_length": 262144},
        "caps": ["completion", "thinking", "tools", "vision"],
    },
    "clef:27b": {
        "ctx": 65536,
        "info": {"qwen35.context_length": 65536},
        "caps": ["decision", "vision"],
    },
}

class Handler(BaseHTTPRequestHandler):
    def _note(self):
        auth = self.headers.get("Authorization") or "-"
        with open(AUTH, "a", encoding="utf-8") as handle:
            handle.write(auth + "\n")

    def _send(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._note()
        if self.path.split("?", 1)[0] != "/api/tags":
            self._send(404, {"error": "not found"})
            return
        models = [{"name": "bad model"}, {"name": "beam[1m]"}]
        for name, spec in MODELS.items():
            models.append({"name": name, "capabilities": spec["caps"]})
        self._send(200, {"models": models})

    def do_POST(self):
        self._note()
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            body = {}
        spec = MODELS.get(body.get("model")) if isinstance(body, dict) else None
        if self.path.split("?", 1)[0] != "/api/show" or spec is None:
            self._send(404, {"error": "not found"})
            return
        self._send(200, {"capabilities": spec["caps"], "model_info": spec["info"]})

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
harness_spawn python3 "${WORK}/catalog.py" "${CATALOG_PORT_FILE}" "${CATALOG_AUTH}"
port=""
for _ in $(seq 1 50); do
    if [[ -s "${CATALOG_PORT_FILE}" ]]; then
        port="$(<"${CATALOG_PORT_FILE}")"
        break
    fi
    sleep 0.05
done
check "catalog fixture published a port" "yes" "$([[ -n "${port}" ]] && echo yes || echo no)"
ready=0
if [[ -n "${port}" ]]; then
    for _ in $(seq 1 50); do
        if curl -fsS -m 1 "http://127.0.0.1:${port}/api/tags" >/dev/null; then
            ready=1
            break
        fi
        sleep 0.05
    done
fi
check "catalog fixture answers /api/tags" "1" "${ready}"

DIRECT_CFG="${WORK}/direct-claude"
mkdir -p "${DIRECT_CFG}"
direct_line="$(OLLAMA_API_KEY="${KEY}" CLAUDE_CONFIG_DIR="${DIRECT_CFG}" \
    python3 "${ROOT_DIR}/lib/kimo-ollama-cloud.py" claude-populate \
    --origin "http://127.0.0.1:${port}" --model beam --context 1000000)"
check "helper prints the catalog count and beam's window" "3 1048576" "${direct_line}"
direct_ok="$(python3 - "${DIRECT_CFG}/settings.json" "${KEY}" <<'PY'
import json, os, stat, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
assert key not in text and "beam[1m]" not in text and "bad model" not in text
assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
opts = json.loads(text)["modelPicker"]["options"]
by_model = {opt["model"]: opt for opt in opts}
assert [opt["model"] for opt in opts] == ["beam", "gemma4:31b", "clef:27b"]
assert by_model["beam"]["description"] == "beam via ollama-cloud · 1048576 ctx · tools, thinking"
assert by_model["beam"]["behavesAs"] == "claude-opus-4-8"
assert by_model["beam"]["kimo"] == "kimo:ollama-cloud"
assert by_model["gemma4:31b"]["description"] == "gemma4:31b via ollama-cloud · 262144 ctx · tools, thinking, vision"
assert by_model["gemma4:31b"]["behavesAs"] == "claude-haiku-4-5"
assert by_model["clef:27b"]["description"] == "clef:27b via ollama-cloud · 65536 ctx · vision, decision"
assert by_model["clef:27b"]["behavesAs"] == "claude-haiku-4-5"
print("direct-ok")
PY
)"
check "helper writes hosted ids, windows, and behavesAs" "direct-ok" "${direct_ok}"
python3 - "${DIRECT_CFG}/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["availableModels"] = ["beam", "keep-me"]
json.dump(doc, open(path, "w", encoding="utf-8"), indent=2)
PY
missing_line="$(OLLAMA_API_KEY="${KEY}" CLAUDE_CONFIG_DIR="${DIRECT_CFG}" \
    python3 "${ROOT_DIR}/lib/kimo-ollama-cloud.py" claude-populate \
    --origin "http://127.0.0.1:${port}" --model muse-spark-open --context 1000000)"
check "a hosted id missing from the catalog reports an unknown window" "4 0" "${missing_line}"
mixed_ok="$(python3 - "${DIRECT_CFG}/settings.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["availableModels"] == ["beam", "keep-me"], doc.get("availableModels")
opts = doc["modelPicker"]["options"]
assert [opt["model"] for opt in opts] == ["muse-spark-open", "beam", "gemma4:31b", "clef:27b"], opts
row = opts[0]
assert row["behavesAs"] == "claude-opus-4-8"
assert "1000000 ctx" in row["description"]
assert row["kimo"] == "kimo:ollama-cloud"
print("mixed-ok")
PY
)"
check "a mixed allowlist stays and the missing id is prepended" "mixed-ok" "${mixed_ok}"

PICKER_DIR="${WORK}/picker-claude"
mkdir -p "${PICKER_DIR}"
cat > "${PICKER_DIR}/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash(ls)"]},
  "availableModels": ["beam", "gemma4:31b", "clef:27b"],
  "modelPicker": {
    "replaceBuiltInOptions": true,
    "options": [
      {"model": "my-custom", "label": "Mine"},
      {"model": "gpt-6.1-sol", "label": "Sol", "kimo": "kimo:codex", "description": "keep me"},
      {"model": "old-cloud", "label": "Old", "kimo": "kimo:ollama-cloud"}
    ]
  }
}
JSON
rm -f "${CAPTURE}"
cat_out="$(OLLAMA_API_KEY="${KEY}" CLAUDE_CONFIG_DIR="${PICKER_DIR}" \
    KIMO_OLLAMA_CLOUD_BASE_URL="http://127.0.0.1:${port}" \
    "${KIMO}" launch claude --provider ollama-cloud 2>&1)" && cat_rc=0 || cat_rc=$?
check "catalog launch exits 0" 0 "${cat_rc}"
check "catalog launch argv is beam" "--model beam" "$(awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -)"
check "catalog launch uses the provider window" "1048576" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
cat_proxy="$(python3 - "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)" "http://127.0.0.1:${port}" <<'PY'
import re, sys
base, fixture = sys.argv[1:]
assert re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", base), base
assert base != fixture, base
print("cat-proxy-ok")
PY
)"
check "catalog launch points claude at the messages proxy" "cat-proxy-ok" "${cat_proxy}"
check "catalog launch is provider-managed" "1" "$(env_val "${CAPTURE}" CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST)"
check_contains "catalog launch names every picker row" "3 models in /model" "${cat_out}"
check_not_contains "catalog launch does not print the key" "${KEY}" "${cat_out}"
picker_ok="$(python3 - "${PICKER_DIR}/settings.json" "${KEY}" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
assert key not in text
doc = json.loads(text)
assert "availableModels" not in doc, doc.get("availableModels")
assert doc["permissions"]["allow"] == ["Bash(ls)"]
assert doc["modelPicker"]["replaceBuiltInOptions"] is True
opts = doc["modelPicker"]["options"]
assert [opt["model"] for opt in opts] == ["my-custom", "gpt-6.1-sol", "beam", "gemma4:31b", "clef:27b"], opts
assert opts[0]["label"] == "Mine"
codex = opts[1]
assert codex["kimo"] == "kimo:codex" and codex["description"] == "keep me"
assert opts[2]["kimo"] == "kimo:ollama-cloud"
assert opts[2]["behavesAs"] == "claude-opus-4-8"
assert "old-cloud" not in text
print("merge-ok")
PY
)"
check "launch keeps user and codex rows and drops the owned allowlist" "merge-ok" "${picker_ok}"

rm -f "${CAPTURE}"
ctx_out="$(OLLAMA_API_KEY="${KEY}" CLAUDE_CONFIG_DIR="${PICKER_DIR}" \
    KIMO_OLLAMA_CLOUD_BASE_URL="http://127.0.0.1:${port}" \
    "${KIMO}" launch claude --provider ollama-cloud --model gemma4:31b --ctx 65536 2>&1)" && ctx_rc=0 || ctx_rc=$?
check "explicit ctx launch exits 0" 0 "${ctx_rc}"
check "explicit ctx argv stays bare" "--model gemma4:31b" "$(awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -)"
check "explicit ctx wins over the catalog window" "65536" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
check_not_contains "explicit ctx output has no [1m] suffix" "[1m]" "${ctx_out}"
ctx_ok="$(python3 - "${PICKER_DIR}/settings.json" <<'PY'
import json, sys
opts = json.load(open(sys.argv[1], encoding="utf-8"))["modelPicker"]["options"]
assert [opt["model"] for opt in opts] == ["my-custom", "gpt-6.1-sol", "gemma4:31b", "beam", "clef:27b"], opts
row = opts[2]
assert row["behavesAs"] == "claude-haiku-4-5"
assert row["description"] == "gemma4:31b via ollama-cloud · 262144 ctx · tools, thinking, vision"
print("ctx-ok")
PY
)"
check "picker keeps the catalog window when --ctx overrides the process" "ctx-ok" "${ctx_ok}"

auth_ok="$(python3 - "${CATALOG_AUTH}" "${KEY}" "${PICKER_DIR}/settings.json" <<'PY'
import pathlib, sys
auth, key, settings = sys.argv[1:]
seen = [line for line in pathlib.Path(auth).read_text(encoding="utf-8").splitlines() if line != "-"]
assert seen and all(line == "Bearer " + key for line in seen), seen[:3]
assert key not in pathlib.Path(settings).read_text(encoding="utf-8")
print("auth-ok")
PY
)"
check "catalog requests carry the bearer and settings do not" "auth-ok" "${auth_ok}"

echo "[6] resumed ids are rewritten before they reach Ollama Cloud"
MSG_UP="${WORK}/msg-up.py"
MSG_BODY="${WORK}/msg-body.json"
MSG_META="${WORK}/msg-meta.txt"
MSG_PORT_FILE="${WORK}/msg-up.port"
cat > "${MSG_UP}" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

body_path, meta_path, port_file = __import__("sys").argv[1:]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length)
        open(body_path, "ab").write(raw + b"\n")
        open(meta_path, "a", encoding="utf-8").write(
            self.path + "\t" + (self.headers.get("Authorization") or "") + "\t"
            + (self.headers.get("x-api-key") or "") + "\n"
        )
        payload = json.loads(raw.decode())
        model = payload.get("model")
        if payload.get("stream"):
            sse = (
                "event: message_start\n"
                f"data: {json.dumps({'type': 'message_start', 'message': {'model': model, 'content': []}})}\n\n"
                "event: content_block_delta\n"
                f"data: {json.dumps({'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': 'ok'}})}\n\n"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(sse)))
            self.end_headers()
            self.wfile.write(sse)
            return
        out = json.dumps({"type": "message", "role": "assistant", "model": model, "content": [{"type": "text", "text": "ok"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_file, "w", encoding="utf-8").write(str(server.server_address[1]))
server.serve_forever()
PY
harness_spawn python3 "${MSG_UP}" "${MSG_BODY}" "${MSG_META}" "${MSG_PORT_FILE}"
msg_tries=0
while [[ ! -s "${MSG_PORT_FILE}" ]]; do
    if ((msg_tries++ > 50)); then
        bad "messages upstream did not start"
        break
    fi
    sleep 0.05
done
MSG_UP_PORT="$(tr -cd '0-9' < "${MSG_PORT_FILE}")"
MSG_PROXY_PORT_FILE="${WORK}/msg-proxy.port"
UPSTREAM_KEY="${KEY}" KIMO_ANTHROPIC_PROXY_CLIENT="client-token-resume" \
    harness_spawn python3 "${ROOT_DIR}/lib/kimo-anthropic-proxy.py" \
    --upstream "http://127.0.0.1:${MSG_UP_PORT}" --wire messages --env-key UPSTREAM_KEY \
    --provider ollama-cloud --model beam --port-file "${MSG_PROXY_PORT_FILE}" --exit-with-pid "$$"
msg_tries=0
while [[ ! -s "${MSG_PROXY_PORT_FILE}" ]]; do
    if ((msg_tries++ > 50)); then
        bad "messages proxy did not start"
        break
    fi
    sleep 0.05
done
MSG_PROXY_PORT="$(tr -cd '0-9' < "${MSG_PROXY_PORT_FILE}")"
plain="$(curl -sS -m 5 -X POST "http://127.0.0.1:${MSG_PROXY_PORT}/v1/messages" \
    -H "x-api-key: client-token-resume" -H 'Content-Type: application/json' \
    -d '{"model":"beam[1m]","max_tokens":8,"stream":false,"messages":[{"role":"user","content":"hi"}]}')"
sse="$(curl -sS -m 5 -X POST "http://127.0.0.1:${MSG_PROXY_PORT}/v1/messages" \
    -H "Authorization: Bearer client-token-resume" -H 'Content-Type: application/json' \
    -d '{"model":"claude-fable-5-2","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}')"
label="$(curl -sS -m 5 -X POST "http://127.0.0.1:${MSG_PROXY_PORT}/v1/messages" \
    -H "x-api-key: client-token-resume" -H 'Content-Type: application/json' \
    -d '{"model":"Fable 5.2","max_tokens":8,"stream":false,"messages":[{"role":"user","content":"hi"}]}')"
resume_ok="$(python3 - "${plain}" "${sse}" "${label}" "${MSG_BODY}" "${MSG_META}" "${KEY}" <<'PY'
import json, sys
plain, sse, label, body_path, meta_path, key = sys.argv[1:]
message = json.loads(plain)
assert message["model"] == "beam[1m]", message
assert "ok" in message["content"][0]["text"]
assert "claude-fable-5-2" in sse, sse
assert "beam[1m]" not in sse
labeled = json.loads(label)
assert labeled["model"] == "Fable 5.2", labeled
seen = [json.loads(line)["model"] for line in open(body_path, encoding="utf-8") if line.strip()]
assert seen == ["beam", "beam", "beam"], seen
meta = [line.rstrip("\n").split("\t") for line in open(meta_path, encoding="utf-8") if line.strip()]
assert meta and all(row[0].rstrip("/") == "/v1/messages" for row in meta), meta
assert all(row[1] == "Bearer " + key for row in meta), meta
assert all(len(row) == 3 and row[2] == "" for row in meta), meta
print("resume-ok")
PY
)"
check "a resumed beam[1m], Fable id, and Fable label all reach ollama as beam" "resume-ok" "${resume_ok}"
bad_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${MSG_PROXY_PORT}/v1/messages" \
    -H 'x-api-key: nope' -H 'Content-Type: application/json' \
    -d '{"model":"beam","max_tokens":1,"messages":[]}')"
check "the messages proxy rejects a bad client token" "401" "${bad_code}"

echo
harness_summary "ollama-cloud-smoke"
