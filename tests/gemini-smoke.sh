#!/usr/bin/env bash
# Headless smoke tests for kimo's 'gemini' command (Google Gemini API -> Kimi Code).
#
# Asserts the command contract without requiring live external network access:
#   * --from-json parses raw /v1beta/models payload without an API key
#   * non-chat / media / embedding families filtered out by default
#   * --all retains non-chat models with generateContent
#   * --stable-only drops preview/experimental tags
#   * token limits (inputTokenLimit -> max_context_size, outputTokenLimit -> max_output_size)
#     are preserved exactly as advertised by the API
#   * thinking capability and multimodal (image_in, video_in) tags emitted
#   * writes valid TOML accepted by python3 tomllib and 'kimi doctor config'
#   * surgical edit: preserves unrelated providers/models and comments
#   * idempotent rewrite: 2nd identical sync leaves config unchanged
#   * creates timestamped backup before modifying config.toml
#   * Gemini provider always references GEMINI_AUTH_TOKEN without embedding a token
#   * legacy API-key options and API-key-only auth are rejected
#   * --set-default updates default_model
#
# Usage: tests/gemini-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

TMPDIR_A="$(mktemp -d)"

# Synthetic fixture containing varied models
FIXTURE="${TMPDIR_A}/fixture.json"
cat > "${FIXTURE}" <<'EOF'
{
  "models": [
    {
      "name": "models/gemini-2.5-flash",
      "displayName": "Gemini 2.5 Flash",
      "inputTokenLimit": 1048576,
      "outputTokenLimit": 65536,
      "supportedGenerationMethods": ["generateContent", "countTokens"],
      "thinking": true
    },
    {
      "name": "models/gemini-2.5-pro",
      "displayName": "Gemini 2.5 Pro",
      "inputTokenLimit": 1048576,
      "outputTokenLimit": 65536,
      "supportedGenerationMethods": ["generateContent", "countTokens"],
      "thinking": true
    },
    {
      "name": "models/gemini-3-flash-preview",
      "displayName": "Gemini 3 Flash Preview",
      "inputTokenLimit": 1048576,
      "outputTokenLimit": 65536,
      "supportedGenerationMethods": ["generateContent"],
      "thinking": true
    },
    {
      "name": "models/gemini-embedding-001",
      "displayName": "Embedding",
      "inputTokenLimit": 2048,
      "outputTokenLimit": 1,
      "supportedGenerationMethods": ["embedContent"],
      "thinking": false
    },
    {
      "name": "models/gemini-2.5-flash-preview-tts",
      "displayName": "TTS Preview",
      "inputTokenLimit": 8192,
      "outputTokenLimit": 16384,
      "supportedGenerationMethods": ["generateContent"],
      "thinking": false
    },
    {
      "name": "models/veo-3.1-generate-preview",
      "displayName": "Veo Video",
      "inputTokenLimit": 480,
      "outputTokenLimit": 8192,
      "supportedGenerationMethods": ["predictLongRunning"],
      "thinking": false
    },
    {
      "name": "models/gemma-4-31b-it",
      "displayName": "Gemma 4 31B IT",
      "inputTokenLimit": 262144,
      "outputTokenLimit": 32768,
      "supportedGenerationMethods": ["generateContent"],
      "thinking": true
    }
  ]
}
EOF

# Initial Kimi config with an existing provider
INIT_CONFIG="${TMPDIR_A}/config.toml"
cat > "${INIT_CONFIG}" <<'EOF'
default_model = "my-custom/model"

[providers.existing]
type = "openai"
base_url = "http://127.0.0.1:11434/v1"
api_key = "local-key"

[models."existing/model"]
provider = "existing"
model = "model"
max_context_size = 32768
max_output_size = 4096
capabilities = [ "tool_use" ]
EOF

echo "[*] testing list-only and filtering contract"
out=$("${KIMO}" gemini --from-json "${FIXTURE}" --list-only)
check "default filters non-chat (tts, embed, veo) out" "4" "$(printf '%s\n' "${out}" | grep -c .)"

stable_out=$("${KIMO}" gemini --from-json "${FIXTURE}" --list-only --stable-only)
check "--stable-only drops preview" "3" "$(printf '%s\n' "${stable_out}" | grep -c .)"
check "--stable-only excludes preview tag" "0" "$(printf '%s\n' "${stable_out}" | grep -c 'preview' || true)"

all_out=$("${KIMO}" gemini --from-json "${FIXTURE}" --list-only --all)
check "--all retains tts (generateContent)" "5" "$(printf '%s\n' "${all_out}" | grep -c .)"

echo "[*] testing config writing & token limits"
TARGET_CONFIG="${TMPDIR_A}/kimi_test.toml"
cp "${INIT_CONFIG}" "${TARGET_CONFIG}"

GEMINI_AUTH_TOKEN="ya29.fixture-gemini-token" "${KIMO}" gemini --config "${TARGET_CONFIG}" --from-json "${FIXTURE}" \
    --set-default "first" >/dev/null

check "target config exists" "true" "$([[ -f "${TARGET_CONFIG}" ]] && echo true || echo false)"
check "existing provider preserved" "1" "$(grep -c '\[providers.existing\]' "${TARGET_CONFIG}")"
check "existing model preserved" "1" "$(grep -c '\[models."existing/model"\]' "${TARGET_CONFIG}")"
check "gemini provider added" "1" "$(grep -c '\[providers.gemini\]' "${TARGET_CONFIG}")"
check "provider type is google-genai" 'type = "google-genai"' "$(grep '^type = "google-genai"' "${TARGET_CONFIG}" | head -1)"
check "default_model rewritten to first" 'default_model = "gemini/gemini-2.5-flash"' "$(grep '^default_model = ' "${TARGET_CONFIG}")"

# Verify token sizes in TOML for gemini-2.5-flash
ctx=$(awk '/^\[models\."gemini\/gemini-2.5-flash"\]/{flag=1; next} /^\[/{flag=0} flag && /max_context_size/{print $3}' "${TARGET_CONFIG}")
out_tokens=$(awk '/^\[models\."gemini\/gemini-2.5-flash"\]/{flag=1; next} /^\[/{flag=0} flag && /max_output_size/{print $3}' "${TARGET_CONFIG}")
check "gemini-2.5-flash max_context_size is 1048576" "1048576" "${ctx}"
check "gemini-2.5-flash max_output_size is 65536" "65536" "${out_tokens}"

# Verify capabilities (thinking, tool_use, image_in, video_in)
caps=$(awk '/^\[models\."gemini\/gemini-2.5-flash"\]/{flag=1; next} /^\[/{flag=0} flag && /capabilities/{print $0}' "${TARGET_CONFIG}")
check "gemini-2.5-flash has thinking capability" "1" "$(echo "${caps}" | grep -c '"thinking"')"
check "gemini-2.5-flash has video_in capability" "1" "$(echo "${caps}" | grep -c '"video_in"')"

echo "[*] testing TOML validity"
python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "${TARGET_CONFIG}"
check "python3 tomllib parses output cleanly" "0" "$?"

if command -v kimi >/dev/null 2>&1; then
    kimi doctor config "${TARGET_CONFIG}" >/dev/null 2>&1
    check "kimi doctor config accepts candidate" "0" "$?"
fi

echo "[*] testing idempotency & backup"
backup_count_before=$(ls "${TARGET_CONFIG}".before-gemini-* 2>/dev/null | wc -l)
content_before=$(cat "${TARGET_CONFIG}")

GEMINI_AUTH_TOKEN="ya29.fixture-gemini-token" "${KIMO}" gemini --config "${TARGET_CONFIG}" --from-json "${FIXTURE}" \
    --set-default "first" >/dev/null

backup_count_after=$(ls "${TARGET_CONFIG}".before-gemini-* 2>/dev/null | wc -l)
check "backup file created" "true" "$([[ ${backup_count_after} -gt ${backup_count_before} ]] && echo true || echo false)"
check "config rewrite is idempotent" "${content_before}" "$(cat "${TARGET_CONFIG}")"

echo "[*] testing fixed bearer environment reference"
GEMINI_AUTH_TOKEN="ya29.fixture-gemini-token" "${KIMO}" gemini --config "${TARGET_CONFIG}" --from-json "${FIXTURE}" >/dev/null

check "api_key_env always references the bearer token" 'api_key_env = "GEMINI_AUTH_TOKEN"' \
    "$(grep '^api_key_env = ' "${TARGET_CONFIG}")"
check "raw api_key is not in gemini provider block" "0" \
    "$(awk '/^\[providers.gemini\]/{flag=1; next} /^\[/{flag=0} flag && /^api_key =/{print}' "${TARGET_CONFIG}" | wc -l)"
check_not_contains "raw bearer token is never written" "ya29.fixture-gemini-token" "$(cat "${TARGET_CONFIG}")"

for legacy_opt in --api-key --api-key-env; do
    rc=0
    legacy_out=$("${KIMO}" gemini --config "${TARGET_CONFIG}" --from-json "${FIXTURE}" \
        "${legacy_opt}" GEMINI_API_KEY 2>&1) || rc=$?
    check "${legacy_opt} is rejected" "1" "${rc}"
    check_contains "${legacy_opt} reports an unknown flag" "unknown flag" "${legacy_out}"
done

rc=0
apikey_out=$(env -u GEMINI_AUTH_TOKEN -u GOOGLE_OAUTH_TOKEN GEMINI_HOME="${TMPDIR_A}/empty-gemini" \
    GEMINI_API_KEY="AIzaSyLegacyKey" "${KIMO}" gemini --config "${TMPDIR_A}/apikey.toml" \
    --from-json "${FIXTURE}" 2>&1) || rc=$?
check "API-key-only auth cannot write Gemini config" "1" "${rc}"
check "API-key-only auth leaves config absent" "false" "$([[ -e "${TMPDIR_A}/apikey.toml" ]] && echo true || echo false)"
check_contains "API-key-only error names GEMINI_AUTH_TOKEN" "GEMINI_AUTH_TOKEN" "${apikey_out}"

echo "[*] testing rejected live catalog cannot fall back to static models"
cat > "${TMPDIR_A}/reject_catalog.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_GET(self):
        body = b'{"error":{"status":"PERMISSION_DENIED","message":"fixture bearer rejected"}}'
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
port_file="${TMPDIR_A}/reject-catalog.port"
harness_spawn python3 "${TMPDIR_A}/reject_catalog.py" "${port_file}"
tries=0
until [[ -s "${port_file}" ]]; do
    ((tries++ < 100)) || { bad "rejection endpoint did not start"; exit 1; }
    sleep 0.05
done
rc=0
rejected_out=$(GEMINI_AUTH_TOKEN="ya29.fixture-rejected-token" "${KIMO}" gemini \
    --base-url "http://127.0.0.1:$(<"${port_file}")" --config "${TMPDIR_A}/rejected.toml" 2>&1) || rc=$?
check "rejected live catalog fails the sync" "1" "${rc}"
check "rejected live catalog writes no config" "false" "$([[ -e "${TMPDIR_A}/rejected.toml" ]] && echo true || echo false)"
check_contains "rejected live catalog reports HTTP 403" "HTTP 403" "${rejected_out}"

echo
echo "gemini smoke: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
