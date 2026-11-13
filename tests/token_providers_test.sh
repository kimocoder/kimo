#!/usr/bin/env bash
# Tests for Claude and Gemini token inspection, export, auto-renewal and launch routing.
#
# Usage: tests/token_providers_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

TMP_DIR="$(mktemp -d "${HARNESS_ROOT}/token_test.XXXXXX")"
CLAUDE_HOME="${TMP_DIR}/claude_home"
GEMINI_HOME="${TMP_DIR}/gemini_home"
GROK_HOME="${TMP_DIR}/grok_home"
KIMI_HOME="${TMP_DIR}/kimi_home"
mkdir -p "${CLAUDE_HOME}" "${GEMINI_HOME}/antigravity-cli" "${GROK_HOME}" "${KIMI_HOME}/.kimi-code"

MOCK_CLAUDE_ACCESS="sk-ant-oat01-test-token-1234567890"
MOCK_CLAUDE_REFRESH="mock-claude-refresh-token"
MOCK_GEMINI_ACCESS="ya29.a0AehfTO-mock-gemini-token"
MOCK_GEMINI_REFRESH="mock-gemini-refresh-token"
MOCK_GROK_ACCESS="eyJ0eXAiOiJhdCtqd3QiLCJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEyMyIsImVtYWlsIjoidGVzdEBleGFtcGxlLmNvbSIsImV4cCI6MTg5MzQ1NjAwMH0.mock-sig"

# Future expiration timestamp (1 hour from now)
FUTURE_EXP_MS=$(( ($(date +%s) + 3600) * 1000 ))
FUTURE_EXP_ISO="$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0) + datetime.timedelta(hours=1))")"

cat > "${CLAUDE_HOME}/.credentials.json" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "${MOCK_CLAUDE_ACCESS}",
    "refreshToken": "${MOCK_CLAUDE_REFRESH}",
    "expiresAt": ${FUTURE_EXP_MS},
    "subscriptionType": "pro",
    "rateLimitTier": "default_claude_ai"
  }
}
EOF

cat > "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token" <<EOF
{
  "token": {
    "access_token": "${MOCK_GEMINI_ACCESS}",
    "refresh_token": "${MOCK_GEMINI_REFRESH}",
    "token_type": "Bearer",
    "expiry": "${FUTURE_EXP_ISO}"
  },
  "id_token_email": "test-user@example.com",
  "auth_method": "consumer"
}
EOF

cat > "${GROK_HOME}/auth.json" <<EOF
{
  "https://auth.x.ai::mock": {
    "key": "${MOCK_GROK_ACCESS}",
    "auth_mode": "oidc",
    "email": "test-grok@example.com",
    "team_id": "team-mock-42",
    "expires_at": "${FUTURE_EXP_ISO}"
  }
}
EOF

printf 'default_model = "unrelated/model"\n' > "${KIMI_HOME}/.kimi-code/config.toml"

echo "[*] [1] kimo claude token, status and export"
export CLAUDE_CONFIG_DIR="${CLAUDE_HOME}"
export KIMI_CONFIG="${KIMI_HOME}/.kimi-code/config.toml"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY

status_out=$("${KIMO}" claude status)
check_contains "claude status finds credentials" "Found" "${status_out}"
check_contains "claude status reports active token" "Active" "${status_out}"
check_contains "claude status reports plan" "pro (default_claude_ai)" "${status_out}"

token_out=$("${KIMO}" claude --token)
check "claude --token prints exact access token" "${MOCK_CLAUDE_ACCESS}" "${token_out}"

token_json=$("${KIMO}" claude --token --json)
check_contains "claude --token --json output has token" "${MOCK_CLAUDE_ACCESS}" "${token_json}"

export_out=$("${KIMO}" claude --export)
check_contains "claude --export exports CLAUDE_CODE_OAUTH_TOKEN" "export CLAUDE_CODE_OAUTH_TOKEN=${MOCK_CLAUDE_ACCESS}" "${export_out}"
check_contains "claude --export exports ANTHROPIC_AUTH_TOKEN" "export ANTHROPIC_AUTH_TOKEN=${MOCK_CLAUDE_ACCESS}" "${export_out}"

json_out=$("${KIMO}" claude --json)
check_contains "claude --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "claude --json reports subscription" '"subscription_type": "pro"' "${json_out}"

sync_out=$("${KIMO}" claude sync)
check_contains "claude sync configures provider" "Synchronized" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote anthropic provider" "[providers.anthropic]" "${cfg_content}"
check_contains "sync registered claude opus" 'claude-opus-5-5' "${cfg_content}"

echo "[*] [2] kimo gemini token, status and export"
export GEMINI_HOME="${GEMINI_HOME}"
unset GEMINI_AUTH_TOKEN GOOGLE_OAUTH_TOKEN GEMINI_API_KEY GOOGLE_API_KEY

status_out=$("${KIMO}" gemini status)
check_contains "gemini status finds credentials" "Found" "${status_out}"
check_contains "gemini status reports account" "test-user@example.com" "${status_out}"
check_contains "gemini status reports active token" "Active" "${status_out}"

token_out=$("${KIMO}" gemini --token)
check "gemini --token prints exact access token" "${MOCK_GEMINI_ACCESS}" "${token_out}"

token_json=$("${KIMO}" gemini --token --json)
check_contains "gemini --token --json output has token" "${MOCK_GEMINI_ACCESS}" "${token_json}"

export_out=$("${KIMO}" gemini --export)
check_contains "gemini --export exports GEMINI_AUTH_TOKEN" "export GEMINI_AUTH_TOKEN=${MOCK_GEMINI_ACCESS}" "${export_out}"

json_out=$("${KIMO}" gemini --json)
check_contains "gemini --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "gemini --json reports email" '"email": "test-user@example.com"' "${json_out}"
check_not_contains "gemini status no longer reports API-key variables" 'GEMINI_API_KEY' "${json_out}"

apikey_state=$(env -u GEMINI_AUTH_TOKEN -u GOOGLE_OAUTH_TOKEN \
    GEMINI_HOME="${TMP_DIR}/empty_gemini_home" GEMINI_API_KEY="AIzaSyLegacyKey" GOOGLE_API_KEY="" \
    python3 "${ROOT_DIR}/lib/kimo-gemini.py" token-state)
check "an API key alone is not Gemini authentication" "missing none no" "${apikey_state}"
rc=0
apikey_out=$(env -u GEMINI_AUTH_TOKEN -u GOOGLE_OAUTH_TOKEN \
    GEMINI_HOME="${TMP_DIR}/empty_gemini_home" GEMINI_API_KEY="AIzaSyLegacyKey" GOOGLE_API_KEY="" \
    "${KIMO}" gemini --token 2>&1) || rc=$?
check "gemini --token rejects API-key-only input" 1 "${rc}"
check_contains "the token error names bearer authentication" "GEMINI_AUTH_TOKEN" "${apikey_out}"

rc=0
helper_noauth_out=$(env -u GEMINI_AUTH_TOKEN -u GOOGLE_OAUTH_TOKEN -u GEMINI_API_KEY -u GOOGLE_API_KEY \
    GEMINI_HOME="${TMP_DIR}/empty_gemini_home" KIMI_CONFIG="${TMP_DIR}/noauth-kimi.toml" \
    python3 "${ROOT_DIR}/lib/kimo-gemini.py" sync 2>&1) || rc=$?
check "helper sync refuses to write static models without a token" 1 "${rc}"
check "helper no-token sync leaves Kimi config absent" "false" "$([[ -e "${TMP_DIR}/noauth-kimi.toml" ]] && echo true || echo false)"
check_contains "helper no-token sync names GEMINI_AUTH_TOKEN" "GEMINI_AUTH_TOKEN" "${helper_noauth_out}"

helper_http=$(python3 - "${ROOT_DIR}/lib/kimo-gemini.py" <<'PY'
import importlib.util
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("kimo_gemini", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Handler(BaseHTTPRequestHandler):
    reject = False
    authorization = None

    def log_message(self, *_args):
        return

    def do_GET(self):
        type(self).authorization = self.headers.get("Authorization")
        status = 401 if type(self).reject else 200
        payload = ({"error": {"message": "denied"}} if type(self).reject else {
            "models": [{"name": "models/gemini-test", "displayName": "Gemini Test",
                        "inputTokenLimit": 1000, "outputTokenLimit": 100,
                        "supportedGenerationMethods": ["generateContent"]}]
        })
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    os.environ["KIMO_GEMINI_BASE_URL"] = f"http://127.0.0.1:{server.server_address[1]}"
    rows = module.fetch_live_models("fixture-oauth-token")
    assert rows[0][0] == "gemini-test"
    assert Handler.authorization == "Bearer fixture-oauth-token"
    Handler.reject = True
    try:
        module.fetch_live_models("fixture-oauth-token")
    except ValueError:
        pass
    else:
        raise AssertionError("401 unexpectedly returned the static model fallback")
finally:
    server.shutdown()
    server.server_close()
    thread.join()
print("bearer-only-ok")
PY
)
check "helper uses bearer auth and propagates catalog rejection" "bearer-only-ok" "${helper_http}"

cat > "${TMP_DIR}/gemini-models.json" <<'JSON'
{"models":[{"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"],"thinking":true}]}
JSON
sync_out=$("${KIMO}" gemini sync --from-json "${TMP_DIR}/gemini-models.json" 2>&1)
check_contains "gemini sync configures provider" "wrote" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote gemini provider" "[providers.gemini]" "${cfg_content}"
check_contains "sync wrote api_key_env for oauth" 'api_key_env = "GEMINI_AUTH_TOKEN"' "${cfg_content}"
check_contains "sync registered gemini flash" 'gemini-2.5-flash' "${cfg_content}"

quota_out=$("${KIMO}" quota --provider gemini)
check_contains "quota reports gemini online" "Gemini: online" "${quota_out}"
check_contains "quota reports model count" "matching models" "${quota_out}"

echo "[*] [3] kimo grok token, status and export"
export GROK_HOME="${GROK_HOME}"
unset XAI_AUTH_TOKEN XAI_API_KEY GROK_AUTH_TOKEN

status_out=$("${KIMO}" grok status)
check_contains "grok status finds credentials" "Found" "${status_out}"
check_contains "grok status reports account" "test-grok@example.com" "${status_out}"
check_contains "grok status reports active token" "Active" "${status_out}"

token_out=$("${KIMO}" grok --token)
check "grok --token prints exact access token" "${MOCK_GROK_ACCESS}" "${token_out}"

token_json=$("${KIMO}" grok --token --json)
check_contains "grok --token --json output has token" "${MOCK_GROK_ACCESS}" "${token_json}"

export_out=$("${KIMO}" grok --export)
check_contains "grok --export exports XAI_AUTH_TOKEN" "export XAI_AUTH_TOKEN=${MOCK_GROK_ACCESS}" "${export_out}"

json_out=$("${KIMO}" grok --json)
check_contains "grok --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "grok --json reports email" '"email": "test-grok@example.com"' "${json_out}"

sync_out=$("${KIMO}" grok sync 2>&1)
check_contains "grok sync configures provider" "Synchronized" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote xai provider" "[providers.xai]" "${cfg_content}"
check_contains "sync wrote api_key_env for oauth" 'api_key_env = "XAI_AUTH_TOKEN"' "${cfg_content}"
check_contains "sync registered grok 4.7" 'grok-4.7' "${cfg_content}"

echo "[*] [3b] GROK_AUTH_TOKEN alias and local-only grok command"
ALIAS_TOKEN="eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJhbGlhcyIsImV4cCI6MTg5MzQ1NjAwMH0.alias-sig"
alias_out=$(env -u XAI_AUTH_TOKEN -u XAI_API_KEY GROK_HOME="${TMP_DIR}/no_grok_home" \
    GROK_AUTH_TOKEN="${ALIAS_TOKEN}" KIMO_GROK_NO_REFRESH=1 "${KIMO}" --remote grok --token 2>&1 || true)
check "GROK_AUTH_TOKEN is accepted as XAI_AUTH_TOKEN" "${ALIAS_TOKEN}" "${alias_out}"
completion_out=$("${KIMO}" completion bash)
check_contains "bash completion offers the grok command" "grok grok-sync xai" "${completion_out}"
check_contains "bash completion handles grok options" "grok|grok-sync|xai|xai-sync|kimi-grok|kimi-xai)" "${completion_out}"
zsh_out=$("${KIMO}" completion zsh)
check_contains "zsh completion describes grok" "'grok:xAI Grok OAuth token" "${zsh_out}"

echo "[*] [4] Launch codex provider auto-resolution with OAuth tokens"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
    GEMINI_API_KEY GEMINI_AUTH_TOKEN GOOGLE_API_KEY GOOGLE_OAUTH_TOKEN \
    XAI_API_KEY XAI_AUTH_TOKEN GROK_AUTH_TOKEN

dry_claude=$("${KIMO}" launch codex --provider claude --dry-run)
check_contains "launch claude uses CLAUDE_CODE_OAUTH_TOKEN env_key" 'env_key=\"CLAUDE_CODE_OAUTH_TOKEN\"' "${dry_claude}"
check_contains "launch claude masks oauth secret" 'CLAUDE_CODE_OAUTH_TOKEN <kept: real value, Anthropic key>' "${dry_claude}"
check_not_contains "dry-run never exposes raw token" "${MOCK_CLAUDE_ACCESS}" "${dry_claude}"

dry_gemini=$("${KIMO}" launch codex --provider gemini --dry-run)
check_contains "launch gemini uses GEMINI_AUTH_TOKEN env_key" 'env_key=\"GEMINI_AUTH_TOKEN\"' "${dry_gemini}"
check_contains "launch gemini masks oauth secret" 'GEMINI_AUTH_TOKEN <kept: real value, Gemini key>' "${dry_gemini}"
check_not_contains "dry-run never exposes raw token" "${MOCK_GEMINI_ACCESS}" "${dry_gemini}"

dry_xai=$("${KIMO}" launch codex --provider xai --dry-run)
check_contains "launch xai uses XAI_AUTH_TOKEN env_key" 'env_key=\"XAI_AUTH_TOKEN\"' "${dry_xai}"
check_contains "launch xai masks oauth secret" 'XAI_AUTH_TOKEN <kept: real value, xAI key>' "${dry_xai}"
check_not_contains "dry-run never exposes raw token" "${MOCK_GROK_ACCESS}" "${dry_xai}"

dry_kimi_xai=$("${KIMO}" launch kimi --provider xai --dry-run)
check_contains "launch kimi xai argv" 'kimi -m xai/grok-4.7' "${dry_kimi_xai}"
check_contains "launch kimi xai masks oauth secret" 'XAI_AUTH_TOKEN <kept: real value, xAI key>' "${dry_kimi_xai}"
check_not_contains "dry-run never exposes raw token to kimi" "${MOCK_GROK_ACCESS}" "${dry_kimi_xai}"

dry_kimi_gemini=$("${KIMO}" launch kimi --provider gemini --dry-run)
check_contains "launch kimi gemini argv" 'kimi -m gemini/gemini-2.5-flash' "${dry_kimi_gemini}"
check_contains "launch kimi gemini masks oauth secret" 'GEMINI_AUTH_TOKEN <kept: real value, Gemini key>' "${dry_kimi_gemini}"
check_not_contains "dry-run never exposes raw token to kimi" "${MOCK_GEMINI_ACCESS}" "${dry_kimi_gemini}"

echo "[*] [5] A stale grok-login JWT must not hide the live auth.json session"
# exp 1600000000 is 2020. The shell copies of this are what cli-chat-proxy 401s
# as reason=no auth context. The file token is the one from section [3].
STALE_GROK_JWT="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzdGFsZSIsImV4cCI6MTYwMDAwMDAwMH0.stale-sig"
state_line=$(XAI_API_KEY="${STALE_GROK_JWT}" XAI_AUTH_TOKEN="${STALE_GROK_JWT}" \
    GROK_HOME="${GROK_HOME}" python3 "${ROOT_DIR}/lib/kimo-grok.py" token-state)
check "stale env does not hide a live session" "valid file no" "${state_line}"

rc=0
stale_dry=$(XAI_API_KEY="${STALE_GROK_JWT}" XAI_AUTH_TOKEN="${STALE_GROK_JWT}" \
    "${KIMO}" launch claude --provider xai --dry-run 2>&1) || rc=$?
check "stale env still launches from auth.json" 0 "${rc}"
check_contains "stale env uses the CLI chat proxy" "host   : https://cli-chat-proxy.grok.com/v1" "${stale_dry}"
check_contains "stale env is replaced by the session token" "secret : XAI_AUTH_TOKEN <kept: real value, xAI key>" "${stale_dry}"
check_contains "the expired shell key is dropped" "secret : XAI_API_KEY <unset>" "${stale_dry}"
check_not_contains "the stale jwt is never printed" "stale-sig" "${stale_dry}"
check_not_contains "the live jwt is never printed" "mock-sig" "${stale_dry}"
check "auth.json is not rewritten for a still-valid session" "${MOCK_GROK_ACCESS}" \
    "$(jq -r '.. | objects | .key? // empty' "${GROK_HOME}/auth.json" | head -1)"

echo "[*] [6] An expired grok-login session is refreshed before launch"
EXPIRED_GROK_JWT="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJleHBpcmVkIiwiZXhwIjoxNjAwMDAwMDAwfQ.expired-sig"
FRESH_GROK_JWT="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJmcmVzaCIsImV4cCI6MTg5MzQ1NjAwMH0.fresh-sig"
cat > "${HARNESS_ROOT}/grok_token_endpoint.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

mode, port_file, log, fresh = sys.argv[1:5]


class H(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(body.decode() + "\n")
        fields = parse_qs(body.decode())
        if mode == "refuse" or fields.get("grant_type") != ["refresh_token"]:
            status, reply = 400, b'{"error":"invalid_grant"}'
        else:
            status = 200
            reply = (
                '{"access_token":"' + fresh + '",'
                '"refresh_token":"rotated-grok-refresh",'
                '"expires_in":3600,"token_type":"Bearer"}'
            ).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


server = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
GROK_PORT_FILE="${HARNESS_ROOT}/grok-token.port"
GROK_TOKEN_LOG="${HARNESS_ROOT}/grok-token.log"
: >"${GROK_TOKEN_LOG}"
rm -f "${GROK_PORT_FILE}"
harness_spawn python3 "${HARNESS_ROOT}/grok_token_endpoint.py" ok "${GROK_PORT_FILE}" "${GROK_TOKEN_LOG}" "${FRESH_GROK_JWT}"
tries=0
until [[ -s "${GROK_PORT_FILE}" ]]; do
    ((tries++ < 100)) || { bad "grok token endpoint did not start"; exit 1; }
    sleep 0.05
done
GROK_TOKEN_URL="http://127.0.0.1:$(<"${GROK_PORT_FILE}")/oauth2/token"

cat > "${GROK_HOME}/auth.json" <<EOF
{
  "https://auth.x.ai::mock-client": {
    "key": "${EXPIRED_GROK_JWT}",
    "auth_mode": "oidc",
    "email": "test-grok@example.com",
    "oidc_client_id": "mock-client",
    "refresh_token": "mock-grok-refresh",
    "expires_at": "2020-09-13T12:26:40Z"
  }
}
EOF
chmod 600 "${GROK_HOME}/auth.json"

rc=0
renewed=$(XAI_API_KEY="${STALE_GROK_JWT}" XAI_AUTH_TOKEN="${STALE_GROK_JWT}" \
    KIMO_GROK_TOKEN_URL="${GROK_TOKEN_URL}" \
    "${KIMO}" launch claude --provider xai --dry-run 2>&1) || rc=$?
check "an expired grok session still launches" 0 "${rc}"
check_contains "the grok renewal is announced" "renewing it from auth.json" "${renewed}"
check_contains "the renewed launch uses the CLI chat proxy" "host   : https://cli-chat-proxy.grok.com/v1" "${renewed}"
check_contains "the renewed launch names the session env" "secret : XAI_AUTH_TOKEN " "${renewed}"
check "auth.json holds the refreshed access token" "${FRESH_GROK_JWT}" \
    "$(jq -r '.. | objects | .key? // empty' "${GROK_HOME}/auth.json" | head -1)"
check "a rotated grok refresh token is stored" "rotated-grok-refresh" \
    "$(jq -r '.. | objects | .refresh_token? // empty' "${GROK_HOME}/auth.json" | head -1)"
check "auth.json stays owner-only" 600 "$(stat -c %a "${GROK_HOME}/auth.json")"
check_contains "the refresh grant is what was posted" "grant_type=refresh_token" "$(cat "${GROK_TOKEN_LOG}")"
check_contains "the stored OIDC client id is posted" "client_id=mock-client" "$(cat "${GROK_TOKEN_LOG}")"
check_not_contains "the refresh token is never printed" "mock-grok-refresh" "${renewed}"
check_not_contains "the refreshed access token is never printed" "fresh-sig" "${renewed}"
check_not_contains "the expired access token is never printed" "expired-sig" "${renewed}"

: >"${GROK_TOKEN_LOG}"
KIMO_GROK_TOKEN_URL="${GROK_TOKEN_URL}" "${KIMO}" launch claude --provider xai --dry-run >/dev/null 2>&1
check "a valid grok session is not refreshed again" 0 "$(wc -l < "${GROK_TOKEN_LOG}" | tr -d ' ')"

cat > "${GROK_HOME}/auth.json" <<EOF
{
  "https://auth.x.ai::mock-client": {
    "key": "${EXPIRED_GROK_JWT}",
    "auth_mode": "oidc",
    "oidc_client_id": "mock-client",
    "refresh_token": "mock-grok-refresh",
    "expires_at": "2020-09-13T12:26:40Z"
  }
}
EOF
rc=0
offline=$(XAI_API_KEY="${STALE_GROK_JWT}" XAI_AUTH_TOKEN="${STALE_GROK_JWT}" \
    KIMO_GROK_NO_REFRESH=1 KIMO_GROK_TOKEN_URL="${GROK_TOKEN_URL}" \
    "${KIMO}" launch claude --provider xai --dry-run 2>&1) || rc=$?
check "KIMO_GROK_NO_REFRESH leaves an expired session unusable" 1 "${rc}"
check_contains "the offline error names the expiry" "expired" "${offline}"
check "offline mode does not post the refresh token" 0 "$(wc -l < "${GROK_TOKEN_LOG}" | tr -d ' ')"
check "offline mode keeps the stored access token" "${EXPIRED_GROK_JWT}" \
    "$(jq -r '.. | objects | .key? // empty' "${GROK_HOME}/auth.json" | head -1)"

echo "[*] [7] An expired gemini session is refreshed before launch"
EXPIRED_GEMINI_ACCESS="ya29.expired-gemini-token"
FRESH_GEMINI_ACCESS="ya29.refreshed-gemini-token"
cat > "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token" <<EOF
{
  "token": {
    "access_token": "${EXPIRED_GEMINI_ACCESS}",
    "refresh_token": "mock-gemini-refresh",
    "token_type": "Bearer",
    "expiry": "2020-09-13T12:26:40Z"
  },
  "id_token_email": "test-user@example.com",
  "auth_method": "consumer"
}
EOF
chmod 600 "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token"

cat > "${HARNESS_ROOT}/gemini_token_endpoint.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

mode, port_file, log, fresh = sys.argv[1:5]


class H(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(body.decode() + "\n")
        fields = parse_qs(body.decode())
        if mode == "refuse" or fields.get("grant_type") != ["refresh_token"]:
            status, reply = 400, b'{"error":"invalid_grant"}'
        else:
            status = 200
            reply = (
                '{"access_token":"' + fresh + '",'
                '"refresh_token":"rotated-gemini-refresh",'
                '"expires_in":3600,"token_type":"Bearer"}'
            ).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


server = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
GEMINI_PORT_FILE="${HARNESS_ROOT}/gemini-token.port"
GEMINI_TOKEN_LOG="${HARNESS_ROOT}/gemini-token.log"
: >"${GEMINI_TOKEN_LOG}"
rm -f "${GEMINI_PORT_FILE}"
harness_spawn python3 "${HARNESS_ROOT}/gemini_token_endpoint.py" ok "${GEMINI_PORT_FILE}" "${GEMINI_TOKEN_LOG}" "${FRESH_GEMINI_ACCESS}"
tries=0
until [[ -s "${GEMINI_PORT_FILE}" ]]; do
    ((tries++ < 100)) || { bad "gemini token endpoint did not start"; exit 1; }
    sleep 0.05
done
GEMINI_TOKEN_URL="http://127.0.0.1:$(<"${GEMINI_PORT_FILE}")/token"

rc=0
renewed=$(GEMINI_API_KEY="" GEMINI_AUTH_TOKEN="${EXPIRED_GEMINI_ACCESS}" \
    KIMO_GEMINI_TOKEN_URL="${GEMINI_TOKEN_URL}" \
    "${KIMO}" launch codex --provider gemini --dry-run 2>&1) || rc=$?
check "an expired gemini session still launches" 0 "${rc}"
check_contains "the gemini renewal is announced" "renewing it from credentials" "${renewed}"
check_contains "the renewed launch names the session env" "secret : GEMINI_AUTH_TOKEN " "${renewed}"
check "antigravity-oauth-token holds the refreshed access token" "${FRESH_GEMINI_ACCESS}" \
    "$(jq -r '.token.access_token // empty' "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token")"
check "a rotated gemini refresh token is stored" "rotated-gemini-refresh" \
    "$(jq -r '.token.refresh_token // empty' "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token")"
check_contains "the refresh grant is what was posted" "grant_type=refresh_token" "$(cat "${GEMINI_TOKEN_LOG}")"
check_not_contains "the refresh token is never printed" "mock-gemini-refresh" "${renewed}"
check_not_contains "the refreshed access token is never printed" "${FRESH_GEMINI_ACCESS}" "${renewed}"
check_not_contains "the expired access token is never printed" "${EXPIRED_GEMINI_ACCESS}" "${renewed}"

echo
harness_summary "token_providers"
