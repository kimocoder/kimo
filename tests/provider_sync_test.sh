#!/usr/bin/env bash
# 'kimo kimi provider sync' credential handling: a provider key is sent only to
# that provider's own base_url, only in a header, and never along a redirect.
#
#   * an openai provider whose /models redirects to another origin: the
#     redirect is not followed and the other origin sees no request at all
#   * an anthropic provider with a base_url (proxy/gateway): the key goes to
#     that base_url, not api.anthropic.com, with or without a trailing /v1
#   * a google-genai provider: x-goog-api-key header, no ?key= in the URL
#   * a non-http(s) base_url is refused before any request is made
#
# Usage: tests/provider_sync_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

FIXTURE="${HARNESS_ROOT}/provider_fixture.py"
PORTS="${HARNESS_ROOT}/fixture.ports"
LOG="${HARNESS_ROOT}/fixture.log"
cat >"${FIXTURE}" <<'PY'
import http.server, json, sys, threading

ports_file, log_file = sys.argv[1], sys.argv[2]
lock = threading.Lock()

def record(server, handler):
    entry = {"server": server, "path": handler.path,
             "authorization": handler.headers.get("Authorization"),
             "x-api-key": handler.headers.get("x-api-key"),
             "x-goog-api-key": handler.headers.get("x-goog-api-key")}
    with lock, open(log_file, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")

def reply(handler, body):
    data = json.dumps(body).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

class Other(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        record("other", self)
        reply(self, {"data": [{"id": "stolen"}]})
    def log_message(self, *args):
        pass

other = http.server.HTTPServer(("127.0.0.1", 0), Other)

class Provider(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        record("provider", self)
        if self.path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{other.server_port}/v1/models")
            self.end_headers()
        elif self.path.startswith("/anth/"):
            reply(self, {"data": [{"id": "claude-fixture"}]})
        elif self.path.startswith("/goog/"):
            reply(self, {"models": [{"name": "models/gemini-fixture"}]})
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args):
        pass

provider = http.server.HTTPServer(("127.0.0.1", 0), Provider)
for srv in (other, provider):
    threading.Thread(target=srv.serve_forever, daemon=True).start()
with open(ports_file, "w", encoding="utf-8") as fh:
    fh.write(f"{provider.server_port}\n")
threading.Event().wait()
PY
: >"${LOG}"
harness_spawn python3 "${FIXTURE}" "${PORTS}" "${LOG}"
tries=0
while [[ ! -s "${PORTS}" ]]; do
    if ((tries++ > 100)) || ! kill -0 "${HARNESS_LAST_PID}" 2>/dev/null; then
        bad "provider fixture did not start"
        exit 1
    fi
    sleep 0.05
done
BASE="http://127.0.0.1:$(<"${PORTS}")"

export KIMI_CONFIG="${HOME}/.kimi-code/config.toml"
mkdir -p "$(dirname "${KIMI_CONFIG}")"
cat >"${KIMI_CONFIG}" <<EOF
[providers.redir]
type = "openai"
base_url = "${BASE}/redirect/v1"
api_key = "sk-redirect-secret"

[providers.anth]
type = "anthropic"
base_url = "${BASE}/anth"
api_key = "sk-anth-secret"

[providers.anthv1]
type = "anthropic"
base_url = "${BASE}/anth/v1"
api_key = "sk-anthv1-secret"

[providers.goog]
type = "google-genai"
base_url = "${BASE}/goog/v1beta"
api_key = "goog-secret-key"

[providers.filey]
type = "openai"
base_url = "file:///etc"
api_key = "sk-file-secret"
EOF

rc=0
out=$("${KIMO}" kimi provider sync --json 2>&1) || rc=$?
status_of() { jq -r --arg id "$1" '.results[] | select(.id == $id) | .status' <<<"${out}" 2>/dev/null; }
error_of() { jq -r --arg id "$1" '.results[] | select(.id == $id) | .error' <<<"${out}" 2>/dev/null; }

echo "[1] Redirects are refused and the key never reaches another origin"
check "redirecting provider is reported as redirected" "redirected" "$(status_of redir)"
check "the other origin received no request" "0" "$(jq -s '[.[] | select(.server == "other")] | length' "${LOG}")"
check "sync exits nonzero when a provider is redirected" "1" "${rc}"

echo "[2] Anthropic keys go to the provider's base_url"
check "anthropic proxy provider syncs" "ok" "$(status_of anth)"
check "anthropic /v1 base_url provider syncs" "ok" "$(status_of anthv1)"
check "base_url without /v1 gets /v1/models appended" "sk-anth-secret" \
    "$(jq -r 'select(.path == "/anth/v1/models" and .["x-api-key"] == "sk-anth-secret") | .["x-api-key"]' "${LOG}")"
check "base_url ending in /v1 is not doubled" "sk-anthv1-secret" \
    "$(jq -r 'select(.path == "/anth/v1/models" and .["x-api-key"] == "sk-anthv1-secret") | .["x-api-key"]' "${LOG}")"
check_not_contains "no /v1/v1 request" "/v1/v1/" "$(cat "${LOG}")"

echo "[3] Google keys travel in x-goog-api-key, never in the URL"
check "google provider syncs" "ok" "$(status_of goog)"
check "google request path has no query string" "/goog/v1beta/models" \
    "$(jq -r 'select(.["x-goog-api-key"] != null) | .path' "${LOG}")"
check "google key is sent as x-goog-api-key" "goog-secret-key" \
    "$(jq -r 'select(.path | startswith("/goog/")) | .["x-goog-api-key"]' "${LOG}")"
check_not_contains "no key= in any request URL" "key=" "$(jq -r '.path' "${LOG}")"

echo "[4] Non-http(s) base URLs are refused"
check "file:// provider is not synced" "parse-error" "$(status_of filey)"
check_contains "file:// refusal names the scheme rule" "not an http(s) URL" "$(error_of filey)"

echo "[5] Synced aliases land in the config"
models=$(python3 -c 'import sys, tomlkit; print(" ".join(tomlkit.parse(open(sys.argv[1]).read()).get("models", {})))' "${KIMI_CONFIG}")
check_contains "anthropic alias written" "anth/claude-fixture" "${models}"
check_contains "google alias written" "goog/gemini-fixture" "${models}"
check_not_contains "nothing from the redirect target" "stolen" "${models}"

harness_summary "provider sync"
