#!/usr/bin/env bash
# Headless smoke tests for kimo's 'codex' authentication bridge,
# 'kimo codex' command, and 'launch' routing with Codex tokens/keys.
#
# Asserts:
#   * _resolve_codex_auth extracts valid JWT bearer tokens from ~/.codex/auth.json
#   * CODEX_API_KEY with JWT format aliases to CODEX_AUTH_TOKEN
#   * CODEX_API_KEY with sk-proj-* maps to OPENAI_API_KEY and loads access_token for CODEX_AUTH_TOKEN
#   * 'kimo codex' status reports tokens, account details, and masks credentials
#   * 'kimo codex --json' returns well-formed JSON schema
#   * 'kimo codex --token' and '--export' output token and shell eval export command
#   * 'kimo codex --sync' upserts [providers.codex] and models into ~/.kimi-code/config.toml
#   * 'kimo codex --set-default' updates default_model
#   * 'kimo launch kimi' with CODEX_API_KEY and cached OAuth routes to codex provider
#   * 'kimo launch codex --provider codex' launches codex on ChatGPT backend without --oss
#   * an expired ChatGPT OAuth token is renewed from auth.json's refresh_token
#     (written back owner-only, no plaintext backup, credential never printed)
#   * KIMO_CODEX_NO_REFRESH=1 stays offline and fails with an actionable hint
#   * '--provider openai' routes kimi/codex at api.openai.com with an sk- key and
#     registers [providers.openai] without ever writing the key to disk
#
# Usage: tests/codex_auth_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# -----------------------------------------------------------------------------
# Setup synthetic Codex auth.json and Kimi config.toml in hermetic HOME
# -----------------------------------------------------------------------------
mkdir -p "${HOME}/.codex" "${HOME}/.kimi-code"

# Never depend on (or start) a developer's installed agent.
FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/codex-call.txt"
mkdir -p "${FAKE_BIN}"
export CODEX_TEST_CAPTURE="${CAPTURE}"
cat > "${FAKE_BIN}/codex" <<'SH'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for key in CODEX_API_KEY CODEX_AUTH_TOKEN CODEX_ACCESS_TOKEN OPENAI_API_KEY OPENAI_BASE_URL CODEX_OSS_BASE_URL OLLAMA_HOST; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
} > "${CODEX_TEST_CAPTURE:?}"
[[ -z "${CODEX_TEST_STDIN:-}" ]] || cat > "${CODEX_TEST_STDIN}"
printf '{"native":true}\n'
exit "${CODEX_TEST_RC:-0}"
SH
cp "${FAKE_BIN}/codex" "${FAKE_BIN}/kimi"
chmod +x "${FAKE_BIN}/codex" "${FAKE_BIN}/kimi"
export PATH="${FAKE_BIN}:${PATH}"

cat > "${HOME}/.codex/models_cache.json" <<'JSON'
{"models":[
  {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","context_window":500000,
   "input_modalities":["text","image"],"default_reasoning_level":"low",
   "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},
  {"slug":"test-codex-text","context_window":32000,"input_modalities":["text"]},
  {"slug":"hidden-model","visibility":"hide","context_window":272000}
]}
JSON

JWT_HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '\n\r=' | tr '/+' '_-')
# Expire in year 2030 (1893456000)
JWT_PAYLOAD=$(printf '{"email":"testuser@example.com","sub":"user-12345","exp":1893456000}' | base64 | tr -d '\n\r=' | tr '/+' '_-')
MOCK_JWT="${JWT_HEADER}.${JWT_PAYLOAD}.mock_signature_bytes_here"

cat > "${HOME}/.codex/auth.json" <<EOF
{
  "auth_mode": "oauth",
  "OPENAI_API_KEY": "sk-proj-file-backup-key-12345",
  "tokens": {
    "account_id": "acc-mock-uuid-67890",
    "access_token": "${MOCK_JWT}",
    "refresh_token": "mock_refresh_token"
  }
}
EOF

echo "[*] [1] _resolve_codex_auth resolution mechanics"

# Test 1.1: Auto-extract from auth.json
(
    unset CODEX_AUTH_TOKEN CODEX_API_KEY OPENAI_API_KEY
    out=$(bash -c "
        CODEX_HOME=\"${HOME}/.codex\"
        source <(sed -n '/^_resolve_codex_auth()/,/^}/p' '${KIMO}')
        _resolve_codex_auth
        echo \"TOKEN=\${CODEX_AUTH_TOKEN}\"
    ")
    check "CODEX_AUTH_TOKEN auto-resolved from auth.json" "TOKEN=${MOCK_JWT}" "${out}"
)

# Test 1.2: CODEX_API_KEY as a JWT (eyJ...) aliases to CODEX_AUTH_TOKEN
(
    CUSTOM_JWT="eyJheader.eyJpayload.signature"
    out=$(bash -c "
        CODEX_HOME=\"${HOME}/.codex\"
        CODEX_API_KEY=\"${CUSTOM_JWT}\"
        source <(sed -n '/^_resolve_codex_auth()/,/^}/p' '${KIMO}')
        _resolve_codex_auth
        echo \"TOKEN=\${CODEX_AUTH_TOKEN}\"
    ")
    check "CODEX_API_KEY (JWT) aliases to CODEX_AUTH_TOKEN" "TOKEN=${CUSTOM_JWT}" "${out}"
)

# Test 1.3: CODEX_API_KEY as sk-proj-* maps to OPENAI_API_KEY and keeps auth.json token
(
    SK_KEY="sk-proj-C7ge5ZgCAzsNKdm5B"
    out=$(bash -c "
        CODEX_HOME=\"${HOME}/.codex\"
        CODEX_API_KEY=\"${SK_KEY}\"
        source <(sed -n '/^_resolve_codex_auth()/,/^}/p' '${KIMO}')
        _resolve_codex_auth
        echo \"OAI=\${OPENAI_API_KEY} TOK=\${CODEX_AUTH_TOKEN}\"
    ")
    check "sk-proj key maps to OPENAI_API_KEY and loads auth token" "OAI=${SK_KEY} TOK=${MOCK_JWT}" "${out}"
)

echo "[*] [2] kimo codex subcommand status, json and token"

# Test 2.1: Default status output
status_out=$("${KIMO}" codex)
check_contains "status contains title" "Codex Authentication & Kimi Code Integration" "${status_out}"
check_contains "status contains found auth file" "Auth File" "${status_out}"
check_contains "status contains account email" "testuser@example.com" "${status_out}"
check_contains "status contains active token" "Active" "${status_out}"
check_not_contains "status does not leak full signature" "mock_signature_bytes_here" "${status_out}"

# Test 2.2: Structured JSON output
json_out=$("${KIMO}" codex --json)
assert_ok "json output parses with jq" jq -e . <<<"${json_out}" >/dev/null
check "json reports auth_file_exists true" "true" "$(jq -r '.auth_file_exists' <<<"${json_out}")"
check "json reports email" "testuser@example.com" "$(jq -r '.email' <<<"${json_out}")"
check "json reports token_valid true" "true" "$(jq -r '.token_valid' <<<"${json_out}")"

# Test 2.3: --token and --export
tok_out=$("${KIMO}" codex --token)
check "kimo codex --token outputs exact access token" "${MOCK_JWT}" "${tok_out}"

exp_out=$("${KIMO}" codex --export)
check_contains "kimo codex --export outputs export statement" "export CODEX_AUTH_TOKEN=" "${exp_out}"

echo "[*] [3] kimo codex sync and set-default"

# Test 3.1: Synchronize with empty kimi config
rm -f "${HOME}/.kimi-code/config.toml"
sync_out=$("${KIMO}" codex --sync)
check_contains "sync reports adding providers.codex" "[providers.codex]" "${sync_out}"
assert_ok "config.toml was created" test -f "${HOME}/.kimi-code/config.toml"

# Verify toml contents
check "providers.codex api_key_env is CODEX_AUTH_TOKEN" "CODEX_AUTH_TOKEN" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print(doc['providers']['codex']['api_key_env'])")"
check "codex/gpt-6.1-sol model registered" "gpt-6.1-sol" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print(doc['models']['codex/gpt-6.1-sol']['model'])")"

# Test 3.2: Set default model
"${KIMO}" codex --set-default codex/gpt-6.1-sol >/dev/null
check "default_model updated" "codex/gpt-6.1-sol" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print(doc.get('default_model'))")"

# Test 3.3: 'codex --set-default openai/<slug>' must not be re-prefixed to
# codex/openai/<slug>; it routes to the metered platform provider as-is.
# Runs on a scratch config so it leaves the shared default_model for [4] alone.
OPENAI_SET_DEFAULT_CONFIG="${HARNESS_ROOT}/openai-setdefault/config.toml"
OPENAI_SET_DEFAULT_KEY="sk-test-openai-setdefault-777"
mkdir -p "$(dirname "${OPENAI_SET_DEFAULT_CONFIG}")"
printf '# scratch for openai set-default\n' > "${OPENAI_SET_DEFAULT_CONFIG}"
rc=0
OPENAI_API_KEY="${OPENAI_SET_DEFAULT_KEY}" KIMI_CONFIG="${OPENAI_SET_DEFAULT_CONFIG}" \
    "${KIMO}" codex --set-default openai/gpt-6.1-sol >/dev/null 2>&1 || rc=$?
check "openai set-default exits clean" 0 "${rc}"
check "openai set-default becomes the default" "openai/gpt-6.1-sol" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${OPENAI_SET_DEFAULT_CONFIG}').read()); print(doc.get('default_model'))")"
check "openai set-default lands under [providers.openai]" "https://api.openai.com/v1" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${OPENAI_SET_DEFAULT_CONFIG}').read()); print(doc['providers']['openai']['base_url'])")"
check "openai alias registered under the openai namespace" "gpt-6.1-sol" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${OPENAI_SET_DEFAULT_CONFIG}').read()); print(doc['models']['openai/gpt-6.1-sol']['model'])")"
check "no mangled codex/openai/ alias" "False" \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${OPENAI_SET_DEFAULT_CONFIG}').read()); print('codex/openai/gpt-6.1-sol' in doc.get('models', {}))")"

echo "[*] [4] kimo launch kimi and codex routing"

# Test 4.1: Launch kimi with CODEX_API_KEY auto-routes to codex/gpt-6.1-sol
kimi_dry=$(CODEX_API_KEY="sk-proj-test-env-key-999" "${KIMO}" launch kimi --dry-run)
check_contains "kimi launch routes to provider codex" "provider: codex" "${kimi_dry}"
check_contains "kimi launch model resolves to codex/gpt-6.1-sol" "model  : codex/gpt-6.1-sol" "${kimi_dry}"
check_contains "kimi launch argv launches kimi with -m" "argv   : kimi -m codex/gpt-6.1-sol" "${kimi_dry}"
check_contains "kimi launch dry-run keeps codex auth secrets" "secret : CODEX_AUTH_TOKEN <kept: real value, codex token/key>" "${kimi_dry}"

# Test 4.2: Launch kimi with --provider codex
kimi_prov_dry=$("${KIMO}" launch kimi --provider codex --dry-run)
check_contains "launch kimi --provider codex routes to codex" "provider: codex" "${kimi_prov_dry}"
check_contains "launch kimi --provider codex uses default codex model" "model  : codex/gpt-6.1-sol" "${kimi_prov_dry}"

# Test 4.3: Launch codex with --provider codex launches ChatGPT backend
codex_dry=$("${KIMO}" launch codex --provider codex --dry-run)
check_contains "launch codex --provider codex routes to codex" "provider: codex" "${codex_dry}"
check_contains "launch codex leaves model selection to native config" "argv   : codex" "${codex_dry}"
check_not_contains "launch codex omits --oss" "--oss" "${codex_dry}"

# Test 4.4: Launch codex with ollama model preserves --oss routing
codex_oss_dry=$("${KIMO}" launch codex --model kalidroid-27b:latest --dry-run)
check_contains "launch codex with ollama model routes to ollama" "provider: ollama" "${codex_oss_dry}"
check_contains "launch codex with ollama model retains --oss" "codex --oss --local-provider ollama --model kalidroid-27b:latest" "${codex_oss_dry}"

echo "[*] [5] Native commands, argv, stdin/stdout and exit status"
native_out=$("${KIMO}" codex exec --json -c 'model_reasoning_effort="high"' 'prompt with spaces')
check "native stdout stays valid JSON" "true" "$(jq -r '.native' <<<"${native_out}")"
check "native argv is preserved" $'exec\n--json\n-c\nmodel_reasoning_effort="high"\nprompt with spaces' \
    "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
"${KIMO}" codex login status >/dev/null
check "native login status forwarded" $'login\nstatus' "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
"${KIMO}" codex --version >/dev/null
check "native --version not swallowed" "--version" "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
"${KIMO}" codex help exec >/dev/null
check "native subcommand help forwarded" $'help\nexec' "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
"${KIMO}" codex --remote wss://codex.example.invalid --remote-auth-token-env TEST_REMOTE_AUTH >/dev/null
check "native remote transport options are untouched" $'--remote\nwss://codex.example.invalid\n--remote-auth-token-env\nTEST_REMOTE_AUTH' \
    "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
rc=0
CODEX_TEST_RC=17 "${KIMO}" codex exec test >/dev/null || rc=$?
check "native failure exit status preserved" 17 "${rc}"
printf 'piped prompt\n' | CODEX_TEST_STDIN="${HARNESS_ROOT}/stdin" "${KIMO}" codex exec - >/dev/null
check "native stdin preserved" 'piped prompt' "$(cat "${HARNESS_ROOT}/stdin")"

launch_out=$(OPENAI_BASE_URL=http://stale.invalid/v1 CODEX_OSS_BASE_URL=http://stale.invalid/v1 \
    "${KIMO}" launch codex --provider openai --model codex/test-model --ctx 12345 -- exec --json 'hello world' 2>/dev/null)
check "launch exec stdout stays valid JSON" true "$(jq -r '.native' <<<"${launch_out}")"
check "launch exec runtime flags follow subcommand" $'exec\n--model\ntest-model\n--config\nmodel_context_window=12345\n--json\nhello world' \
    "$(sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d')"
check "native launch clears stale OpenAI URL" '<unset>' "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
check "native launch clears OSS URL" '<unset>' "$(env_val "${CAPTURE}" CODEX_OSS_BASE_URL)"
"${KIMO}" --host http://127.0.0.1:9 launch codex --model test-local -c 'model_reasoning_effort="low"' -- exec --json hi >/dev/null 2>&1
check_contains "Ollama exec gets runtime provider flags" $'exec\n--oss\n--local-provider\nollama' "$(cat "${CAPTURE}")"
check_contains "native -c reaches child" 'model_reasoning_effort="low"' "$(cat "${CAPTURE}")"

echo "[*] [6] Provider precedence, supported CLIs and secrets"
"${KIMO}" config set cloud_provider codex >/dev/null
check "config accepts codex backend" codex "$("${KIMO}" config get cloud_provider)"
forced=$(CODEX_AUTH_TOKEN="${MOCK_JWT}" "${KIMO}" launch codex --provider ollama --dry-run)
check_contains "explicit Ollama wins over credentials and config" 'provider: ollama' "${forced}"
"${KIMO}" config unset cloud_provider >/dev/null
rc=0
"${KIMO}" launch claude --provider codex --dry-run >/dev/null 2>&1 || rc=$?
check "unsupported cloud CLI rejected" 1 "${rc}"
CODEX_API_KEY=fixture-api-secret CODEX_AUTH_TOKEN="${MOCK_JWT}" CODEX_ACCESS_TOKEN=fixture-access-secret \
    "${KIMO}" --host http://remote.kimo-test.invalid:9 launch codex --provider ollama --model test-local >/dev/null 2>&1
for key in CODEX_API_KEY CODEX_AUTH_TOKEN CODEX_ACCESS_TOKEN; do
    check "remote Ollama clears ${key}" '<unset>' "$(env_val "${CAPTURE}" "${key}")"
done
explicit=$(CODEX_API_KEY=eyJother.token.signature CODEX_AUTH_TOKEN="${MOCK_JWT}" "${KIMO}" codex --token)
check "explicit CODEX_AUTH_TOKEN takes precedence" "${MOCK_JWT}" "${explicit}"
masked=$(CODEX_API_KEY=fixture-api-secret "${KIMO}" --json launch codex --provider codex --dry-run)
check_not_contains "JSON dry-run masks all Codex credentials" fixture-api-secret "${masked}"
access_route=$(CODEX_ACCESS_TOKEN=fixture-access-secret "${KIMO}" launch codex --dry-run)
check_contains "native access token selects OpenAI backend" 'provider: codex' "${access_route}"

# The native path must not discover or query Ollama, even when --remote would
# normally resolve the tunnel and several hosts were passed globally.
cat > "${FAKE_BIN}/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_TEST_CAPTURE}.curl"
exit 7
SH
chmod +x "${FAKE_BIN}/curl"
( unset OLLAMA_REMOTE_URL; "${KIMO}" --remote launch codex --provider codex --dry-run >/dev/null )
"${KIMO}" --host one.invalid --host two.invalid launch codex --provider codex --model codex/test-model --dry-run >/dev/null
check "native routing never probes Ollama" no "$([[ -f "${CAPTURE}.curl" ]] && echo yes || echo no)"
rm "${FAKE_BIN}/curl"

echo "[*] [7] Safe model sync and configurable paths"
check "catalog context used" 500000 "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read())['models']['codex/gpt-6.1-sol']['max_context_size'])")"
check "reasoning codex models declare an off effort for kimi" low \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read())['models']['codex/gpt-6.1-sol']['off_effort'])")"
check "non-reasoning codex models declare no off effort" absent \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print('absent' if 'off_effort' not in doc['models']['codex/test-codex-text'] else 'present')")"
check_not_contains "hidden models not registered" hidden-model "$(cat "${HOME}/.kimi-code/config.toml")"
again=$("${KIMO}" codex --sync --json)
check "sync is idempotent" false "$(jq -r '.changed' <<<"${again}")"
alias_sync=$("${KIMO}" codex-sync --json)
check "codex-sync alias synchronizes models" false "$(jq -r '.changed' <<<"${alias_sync}")"
# A provider block left behind by an older kimo is repaired, not preserved.
python3 -c "import tomlkit; p = '${HOME}/.kimi-code/config.toml'; doc = tomlkit.parse(open(p).read()); doc['providers']['codex']['custom_headers'] = {'originator': 'stale'}; doc['providers']['codex']['api_key'] = 'stale-static'; open(p, 'w').write(tomlkit.dumps(doc))"
repair=$("${KIMO}" codex --sync --json)
check "sync repairs a stale provider block" true "$(jq -r '.changed' <<<"${repair}")"
check "stale custom_headers are dropped" absent \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print('absent' if 'custom_headers' not in doc['providers']['codex'] else 'present')")"
check "stale static api_key is dropped" absent \
    "$(python3 -c "import tomlkit; doc = tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read()); print('absent' if 'api_key' not in doc['providers']['codex'] else 'present')")"
rc=0
"${KIMO}" codex --set-default nonexistent-model >/dev/null 2>&1 || rc=$?
check "unknown default model rejected" 1 "${rc}"

CUSTOM_CONFIG="${HARNESS_ROOT}/custom/config.toml"
mkdir -p "$(dirname "${CUSTOM_CONFIG}")"
printf '# keep this comment\ndefault_model = "unrelated/model"\n' > "${CUSTOM_CONFIG}"
custom=$(KIMI_CONFIG="${CUSTOM_CONFIG}" "${KIMO}" codex --sync --json)
check_contains "sync preserves unrelated comments" '# keep this comment' "$(cat "${CUSTOM_CONFIG}")"
assert_ok "sync backs up original config" test -f "$(jq -r '.backup' <<<"${custom}")"
custom_status=$(KIMI_CONFIG="${CUSTOM_CONFIG}" "${KIMO}" codex --json)
check "status respects custom config path" "${CUSTOM_CONFIG}" "$(jq -r '.kimi.config_file' <<<"${custom_status}")"
check "sync keeps unrelated default model" unrelated/model "$(jq -r '.kimi.default_model' <<<"${custom_status}")"
printf '[broken\n' > "${CUSTOM_CONFIG}"
rc=0
KIMI_CONFIG="${CUSTOM_CONFIG}" "${KIMO}" codex --sync >/dev/null 2>&1 || rc=$?
check "malformed TOML rejected" 1 "${rc}"
check "malformed config preserved" '[broken' "$(cat "${CUSTOM_CONFIG}")"
rm "${CUSTOM_CONFIG}"
ln -s "${HOME}/.kimi-code/config.toml" "${CUSTOM_CONFIG}"
rc=0
KIMI_CONFIG="${CUSTOM_CONFIG}" "${KIMO}" codex --sync >/dev/null 2>&1 || rc=$?
check "symlink config rejected" 1 "${rc}"

"${KIMO}" launch kimi --provider codex --model test-codex-text -- --print hi >/dev/null 2>&1
check "Kimi launch syncs selected model" codex/test-codex-text \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${HOME}/.kimi-code/config.toml').read())['default_model'])")"
mv "${HOME}/.codex" "${HOME}/alternate-codex"
alternate=$(CODEX_HOME="${HOME}/alternate-codex" "${KIMO}" codex --json)
check "status respects CODEX_HOME" true "$(jq -r '.auth_file_exists' <<<"${alternate}")"
no_auth=$("${KIMO}" codex --json)
check "missing auth reported without failure" false "$(jq -r '.token_present' <<<"${no_auth}")"
rc=0
CODEX_API_KEY=sk-test-platform-key "${KIMO}" launch kimi --provider codex --dry-run >/dev/null 2>&1 || rc=$?
check "Platform API key never substituted for ChatGPT OAuth" 1 "${rc}"
rc=0
"${KIMO}" codex --sync >/dev/null 2>&1 || rc=$?
check "missing catalog does not invent models" 0 "${rc}"

mkdir -p "${HOME}/.codex"
printf '{"tokens":null}' > "${HOME}/.codex/auth.json"
malformed=$("${KIMO}" codex --json)
check "malformed token storage is tolerated" false "$(jq -r '.token_present' <<<"${malformed}")"
EXPIRED_PAYLOAD=$(printf '{"exp":1}' | base64 | tr -d '\n\r=' | tr '/+' '_-')
expired=$(CODEX_AUTH_TOKEN="${JWT_HEADER}.${EXPIRED_PAYLOAD}.fixture" "${KIMO}" codex --json)
check "expired token reported accurately" false "$(jq -r '.token_valid' <<<"${expired}")"
rc=0
CODEX_AUTH_TOKEN="${JWT_HEADER}.${EXPIRED_PAYLOAD}.fixture" "${KIMO}" launch kimi --provider codex --dry-run >/dev/null 2>&1 || rc=$?
check "Kimi rejects expired OAuth before launching" 1 "${rc}"
empty_config="${HARNESS_ROOT}/no-catalog/config.toml"
rc=0
KIMI_CONFIG="${empty_config}" "${KIMO}" codex --sync >/dev/null 2>&1 || rc=$?
check "new sync requires a cached model catalog" 1 "${rc}"
check "failed sync leaves config absent" no "$([[ -e "${empty_config}" ]] && echo yes || echo no)"

echo "[*] [8] ChatGPT OAuth renewal"

# Section [7] moved ~/.codex aside and left a tokenless auth.json behind; restore
# a catalog so the launch path can resolve a model again.
CODEX_DIR="${HOME}/.codex"
mkdir -p "${CODEX_DIR}"
cp "${HOME}/alternate-codex/models_cache.json" "${CODEX_DIR}/models_cache.json"

STALE_JWT="${JWT_HEADER}.${EXPIRED_PAYLOAD}.stale_signature_bytes"
FRESH_PAYLOAD=$(printf '{"email":"testuser@example.com","exp":1893456000}' | base64 | tr -d '\n\r=' | tr '/+' '_-')
FRESH_JWT="${JWT_HEADER}.${FRESH_PAYLOAD}.fresh_signature_bytes"

# A loopback OAuth token endpoint. The harness proxy only lets loopback through,
# so KIMO_CODEX_TOKEN_URL is the seam that keeps this test offline.
cat > "${HARNESS_ROOT}/token_endpoint.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, port_file, log, fresh = sys.argv[1:5]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}"
        with open(log, "a") as fh:
            fh.write(body.decode() + "\n")
        if mode == "refuse":
            status, reply = 400, {"error": "invalid_grant"}
        else:
            status, reply = 200, {"access_token": fresh, "refresh_token": "rotated_refresh_token",
                                  "id_token": "id.token.value", "expires_in": 3600, "token_type": "Bearer"}
        data = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY

start_token_endpoint() { # <mode> -> sets TOKEN_URL, TOKEN_LOG
    local port_file="${HARNESS_ROOT}/token-$1.port" tries=0
    TOKEN_LOG="${HARNESS_ROOT}/token-$1.log"
    : > "${TOKEN_LOG}"
    rm -f "${port_file}"
    harness_spawn python3 "${HARNESS_ROOT}/token_endpoint.py" "$1" "${port_file}" "${TOKEN_LOG}" "${FRESH_JWT}"
    until [[ -s "${port_file}" ]]; do
        ((tries++ < 100)) || { bad "token endpoint '$1' did not start"; exit 1; }
        sleep 0.05
    done
    TOKEN_URL="http://127.0.0.1:$(<"${port_file}")/oauth/token"
}

write_auth() { # [access_token] [refresh_token]
    cat > "${CODEX_DIR}/auth.json" <<EOF
{
  "auth_mode": "oauth",
  "OPENAI_API_KEY": null,
  "tokens": {
    "account_id": "acc-mock-uuid-67890",
    "access_token": "${1-}",
    "refresh_token": "${2-mock_refresh_token}"
  }
}
EOF
    chmod 600 "${CODEX_DIR}/auth.json"
}
auth_field() { jq -r ".tokens.$1 // \"<none>\"" "${CODEX_DIR}/auth.json"; }
codex_dir_entries() { ls -A "${CODEX_DIR}" | wc -l | tr -d ' '; }

start_token_endpoint ok
write_auth "${STALE_JWT}"
rc=0
renewed=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" launch kimi --provider codex --dry-run 2>&1) || rc=$?
check "an expired OAuth token still launches" 0 "${rc}"
check_contains "the renewal is announced" "renewing it from" "${renewed}"
check_contains "the renewed launch routes to codex" "provider: codex" "${renewed}"
check "auth.json holds the new access token" "${FRESH_JWT}" "$(auth_field access_token)"
check "a rotated refresh token is stored" rotated_refresh_token "$(auth_field refresh_token)"
check "last_refresh is recorded" true "$(jq -r 'has("last_refresh")' "${CODEX_DIR}/auth.json")"
check "auth.json stays owner-only" 600 "$(stat -c %a "${CODEX_DIR}/auth.json")"
check "no plaintext credential backup is left behind" 2 "$(codex_dir_entries)"
check_contains "the refresh grant is what was posted" '"grant_type": "refresh_token"' "$(cat "${TOKEN_LOG}")"
check_contains "the Codex CLI client id is used" app_EMoamEEZ73f0CkXaXp7hrann "$(cat "${TOKEN_LOG}")"
check_not_contains "the refresh token is never printed" mock_refresh_token "${renewed}"
check_not_contains "the stale token is never printed" stale_signature_bytes "${renewed}"
check_not_contains "the renewed token is never printed" fresh_signature_bytes "${renewed}"

: > "${TOKEN_LOG}"
KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" launch kimi --provider codex --dry-run >/dev/null 2>&1
check "a valid token is not refreshed again" 0 "$(wc -l < "${TOKEN_LOG}" | tr -d ' ')"

write_auth "${STALE_JWT}"
tok=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" codex --token)
check "--token renews a stale token" "${FRESH_JWT}" "${tok}"
write_auth "${STALE_JWT}"
export_line=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" codex --export)
check "--export stays a single eval-able line" 1 "$(grep -c . <<<"${export_line}")"
check_contains "--export renews before printing" "export CODEX_AUTH_TOKEN=" "${export_line}"

status_json=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" codex --json)
check "status reports the refresh token" true "$(jq -r '.refreshable' <<<"${status_json}")"
check "status reports the renewal timestamp" true "$(jq -r '.last_refresh != null' <<<"${status_json}")"

write_auth "${STALE_JWT}"
: > "${TOKEN_LOG}"
rc=0
offline=$(KIMO_CODEX_NO_REFRESH=1 KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" launch kimi --provider codex --dry-run 2>&1) || rc=$?
check "the renewal can be switched off" 1 "${rc}"
check "a switched-off renewal makes no request" 0 "$(wc -l < "${TOKEN_LOG}" | tr -d ' ')"
check_contains "the failure names the token state" expired "${offline}"
check_contains "the failure says how to sign in" "codex login" "${offline}"

start_token_endpoint refuse
write_auth "${STALE_JWT}"
rc=0
refused=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" launch kimi --provider codex --dry-run 2>&1) || rc=$?
check "a refused renewal fails the launch" 1 "${rc}"
check_contains "a refused renewal points at signing in" "codex login" "${refused}"
check "a refused renewal leaves the access token alone" "${STALE_JWT}" "$(auth_field access_token)"
check "a refused renewal keeps the old refresh token" mock_refresh_token "$(auth_field refresh_token)"

start_token_endpoint ok
printf '{"auth_mode":"oauth","tokens":{"account_id":"acc-1"}}' > "${CODEX_DIR}/auth.json"
rc=0
nologin=$(KIMO_CODEX_TOKEN_URL="${TOKEN_URL}" "${KIMO}" launch kimi --provider codex --dry-run 2>&1) || rc=$?
check "no login and no refresh token fails" 1 "${rc}"
check_contains "the missing-token hint offers the platform backend" "--provider openai" "${nologin}"
check_contains "the missing-token hint offers sign-in" "codex login" "${nologin}"

echo "[*] [9] --provider openai: the metered platform API"

PLATFORM_KEY=sk-test-platform-key-12345
KIMI_TOML="${HOME}/.kimi-code/config.toml"
dry=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --provider openai --dry-run)
check_contains "the platform backend is reported" "provider: openai" "${dry}"
check_contains "the platform host is api.openai.com" "host   : https://api.openai.com" "${dry}"
check_contains "platform models use their own namespace" "model  : openai/gpt-6.1-sol" "${dry}"
check_contains "kimi is launched with the platform alias" "argv   : kimi -m openai/gpt-6.1-sol" "${dry}"
check_contains "the platform key is masked" "secret : OPENAI_API_KEY <kept: real value, OpenAI platform key>" "${dry}"
check_not_contains "the dry run never prints the key" "${PLATFORM_KEY}" "${dry}"
check_contains "a hosted API does not evict" "evict  : n/a" "${dry}"

OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --provider openai >/dev/null
check "kimi receives the platform alias" "openai/gpt-6.1-sol" "$(flag_val "${CAPTURE}" -m)"
check "kimi receives the real platform key" "${PLATFORM_KEY}" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
check "no Ollama host is exported" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
check "no stale OpenAI base URL is exported" "<unset>" "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
check "no ChatGPT token is sent to the platform backend" "<unset>" "$(env_val "${CAPTURE}" CODEX_AUTH_TOKEN)"
check "[providers.openai] points at the platform API" "https://api.openai.com/v1" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${KIMI_TOML}').read())['providers']['openai']['base_url'])")"
check "[providers.openai] names the key's env var" "OPENAI_API_KEY" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${KIMI_TOML}').read())['providers']['openai']['api_key_env'])")"
check "[providers.openai] speaks the Responses API" "openai_responses" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${KIMI_TOML}').read())['providers']['openai']['type'])")"
check "the platform alias becomes the default model" "openai/gpt-6.1-sol" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${KIMI_TOML}').read())['default_model'])")"
check_not_contains "the platform key is never written to disk" "${PLATFORM_KEY}" "$(cat "${KIMI_TOML}")"
check_not_contains "no static api_key is written" "api_key =" "$(cat "${KIMI_TOML}")"

dry=$(CODEX_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --provider openai --dry-run)
check_contains "CODEX_API_KEY works as a platform key" "provider: openai" "${dry}"

dry=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch codex --provider openai --dry-run)
check_contains "the codex CLI accepts the platform backend" "provider: openai" "${dry}"
check_contains "the codex CLI keeps its own model choice" "argv   : codex" "${dry}"
check_not_contains "no --oss on the platform backend" "--oss" "${dry}"

rc=0
nokey=$("${KIMO}" launch kimi --provider openai --dry-run 2>&1) || rc=$?
check "a missing platform key fails" 1 "${rc}"
check_contains "the missing-key error names the variable" "OPENAI_API_KEY" "${nokey}"
check_contains "the missing-key error offers the ChatGPT backend" "--provider codex" "${nokey}"
rc=0
OPENAI_API_KEY=ollama "${KIMO}" launch kimi --provider openai --dry-run >/dev/null 2>&1 || rc=$?
check "kimo's own placeholder is not sent to OpenAI" 1 "${rc}"

NO_OAUTH="${HARNESS_ROOT}/platform-only"
mkdir -p "${NO_OAUTH}"
cp "${CODEX_DIR}/models_cache.json" "${NO_OAUTH}/"
dry=$(CODEX_HOME="${NO_OAUTH}" OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --dry-run)
check_contains "a lone platform key auto-selects the platform backend" "provider: openai" "${dry}"

rc=0
unsupported=$("${KIMO}" launch claude --provider openai --dry-run 2>&1) || rc=$?
check "claude has no OpenAI backend branch" 1 "${rc}"
check_contains "the rejection names the supported CLIs" "codex kimi" "${unsupported}"

"${KIMO}" config set cloud_provider openai >/dev/null
check "config accepts the openai backend" openai "$("${KIMO}" config get cloud_provider)"
dry=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --dry-run)
check_contains "the configured backend is used" "provider: openai" "${dry}"
"${KIMO}" config unset cloud_provider >/dev/null

rc=0
unknown=$("${KIMO}" launch kimi --provider grok --dry-run 2>&1) || rc=$?
check "an unknown backend is rejected" 1 "${rc}"
check_contains "the rejection lists every backend" "ollama abliteration codex openai" "${unknown}"
rc=0
missing=$("${KIMO}" launch kimi --provider 2>&1) || rc=$?
check "a missing backend argument is rejected" 1 "${rc}"
check_contains "the missing-argument error lists every backend" "ollama, abliteration, codex, openai" "${missing}"

# An explicitly requested model needs no cached catalog, so a box that has never
# run the Codex CLI can still use the platform backend.
BARE_HOME="${HARNESS_ROOT}/bare-codex-home"
BARE_TOML="${HARNESS_ROOT}/bare-config/config.toml"
mkdir -p "${BARE_HOME}" "$(dirname "${BARE_TOML}")"
rc=0
CODEX_HOME="${BARE_HOME}" KIMI_CONFIG="${BARE_TOML}" OPENAI_API_KEY="${PLATFORM_KEY}" \
    "${KIMO}" launch kimi --provider openai --model gpt-5.1-codex >/dev/null 2>&1 || rc=$?
check "an explicit model needs no cached catalog" 0 "${rc}"
check "the explicit model is registered" "gpt-5.1-codex" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${BARE_TOML}').read())['models']['openai/gpt-5.1-codex']['model'])")"
check "the explicit model becomes the default" "openai/gpt-5.1-codex" \
    "$(python3 -c "import tomlkit; print(tomlkit.parse(open('${BARE_TOML}').read())['default_model'])")"

# Codex follows auth.json's auth_mode, not the environment: with a ChatGPT login
# stored it bills the plan even though OPENAI_API_KEY is exported. kimo says so
# instead of implying the platform key took effect. (kimi is explicit via
# api_key_env, so it must not be warned about.)
write_auth "${FRESH_JWT}"
warn=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch codex --provider openai --dry-run 2>&1 >/dev/null)
check_contains "a stored ChatGPT login is called out" "prefers it over" "${warn}"
check_contains "the warning says how to switch" "login --with-api-key" "${warn}"
check_contains "the warning names the billing consequence" "ChatGPT plan" "${warn}"
kimi_warn=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch kimi --provider openai --dry-run 2>&1 >/dev/null)
check_not_contains "kimi is not warned (its provider names the key)" "prefers it over" "${kimi_warn}"
printf '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-fake-stored-key","tokens":null}' > "${CODEX_DIR}/auth.json"
quiet=$(OPENAI_API_KEY="${PLATFORM_KEY}" "${KIMO}" launch codex --provider openai --dry-run 2>&1 >/dev/null)
check_not_contains "apikey mode needs no warning" "prefers it over" "${quiet}"

bash_completion=$("${KIMO}" completion bash)
check_contains "Bash completion includes Codex native commands" 'exec review resume fork' "${bash_completion}"
# Both completion scripts are emitted from quoted heredocs, so they cannot expand
# KIMO_LAUNCH_PROVIDERS; assert they still offer exactly what launch accepts.
providers=$(sed -n 's/^KIMO_LAUNCH_PROVIDERS="\(.*\)"$/\1/p' "${KIMO}")
check "the accepted backends are declared once" "ollama abliteration codex openai dashscope" "${providers}"
check_contains "Bash completion offers every backend" "${providers}" "${bash_completion}"
check_contains "Zsh completion offers every backend" "${providers}" "$("${KIMO}" completion zsh)"
check_contains "Zsh completion includes Codex bridge" '--sync[Synchronize Codex provider' "$("${KIMO}" completion zsh)"
comp_script="${HARNESS_ROOT}/comp.bash"
"${KIMO}" completion bash > "${comp_script}"
comp_codex=$(CODEX_HOME="${HOME}/.codex" bash -c "source '${comp_script}'; COMP_WORDS=(kimo launch kimi --provider codex -m ''); COMP_CWORD=6; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_contains "completion offers codex catalog models with --provider codex" "codex/gpt-6.1-sol" "${comp_codex}"
check_not_contains "completion hides hidden catalog models" "codex/hidden-model" "${comp_codex}"
comp_plain=$(CODEX_HOME="${HOME}/.codex" bash -c "source '${comp_script}'; COMP_WORDS=(kimo launch kimi -m ''); COMP_CWORD=4; _kimo; printf '%s\n' \"\${COMPREPLY[@]}\"")
check_not_contains "no hosted aliases without --provider" "codex/gpt-6.1-sol" "${comp_plain}"
check_contains "zsh completion embeds the hosted model helper" "_kimo_hosted_models" "$("${KIMO}" completion zsh)"

echo
harness_summary "codex_auth_test"
