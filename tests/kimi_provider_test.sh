#!/usr/bin/env bash
# 'kimo kimi provider' list/disable/enable/sync against a private Kimi config:
#
#   * disable/enable round-trips: every alias disable hides (by provider field
#     or "<pid>/" prefix) comes back, and so does the default_model it cleared,
#     unless another default was chosen meanwhile; aliases an older kimo left
#     hidden on an enabled provider are rescued
#   * sync persists refreshed metadata even when no model is new, skips
#     non-chat models unless --include-nonchat, and --prune clears non-chat
#     aliases an earlier sync added
#   * CLI: --all, value checks for --timeout/--jobs, exit codes, and an
#     unknown 'kimi' subcommand failing cleanly
#
# Usage: tests/kimi_provider_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

export KIMI_CONFIG="${HOME}/.kimi-code/config.toml"
mkdir -p "$(dirname "${KIMI_CONFIG}")"

# toml <python expression over doc>: print a value read from the config.
toml() {
    python3 -c 'import sys, tomlkit; doc = tomlkit.parse(open(sys.argv[1]).read()); print(eval(sys.argv[2]))' \
        "${KIMI_CONFIG}" "$1"
}

echo "[1] disable/enable round trip"
cat >"${KIMI_CONFIG}" <<'EOF'
default_model = "myalias"

[providers.foo]
type = "openai"
base_url = "http://127.0.0.1:9/v1"
api_key = "sk-foo"

[providers.bar]
type = "openai"
base_url = "http://127.0.0.1:9/v1"
api_key = "sk-bar"

[models."foo/m1"]
provider = "foo"
model = "m1"

[models.myalias]
provider = "foo"
model = "m2"

[models."bar/b1"]
provider = "bar"
model = "b1"
EOF
cp "${KIMI_CONFIG}" "${HARNESS_ROOT}/original.toml"

out=$("${KIMO}" kimi provider disable foo 2>&1)
check_contains "disable hides both aliases" "2 model aliases hidden" "${out}"
check "provider-field alias is hidden" True "$(toml '"myalias" in doc["disabled_models"]')"
check "default_model on a hidden alias is cleared" False "$(toml '"default_model" in doc')"
check "cleared default is remembered" myalias "$(toml 'doc["disabled_defaults"]["foo"]')"
check "list counts hidden aliases by provider field too" 2 \
    "$("${KIMO}" kimi provider list --json | jq -r '.disabled_providers[] | select(.id == "foo") | .models')"

out=$("${KIMO}" kimi provider enable foo 2>&1)
check_contains "enable restores both aliases" "2 model aliases restored" "${out}"
check_contains "enable reports the restored default" "default_model restored to 'myalias'" "${out}"
check "round trip leaves the same providers, models and default" "same" "$(python3 -c '
import sys, tomlkit
a, b = (tomlkit.parse(open(p).read()).unwrap() for p in sys.argv[1:])
print("same" if a == b else f"differs: {a} != {b}")' "${HARNESS_ROOT}/original.toml" "${KIMI_CONFIG}")"

"${KIMO}" kimi provider disable foo >/dev/null 2>&1
sed -i '1i default_model = "bar/b1"' "${KIMI_CONFIG}"
out=$("${KIMO}" kimi provider enable foo 2>&1)
check "a default chosen meanwhile is kept" bar/b1 "$(toml 'doc["default_model"]')"
check_contains "enable says why it kept the newer default" "was set since" "${out}"
check "the remembered default is dropped once used" False "$(toml '"disabled_defaults" in doc')"

echo "[2] enable rescues aliases an older kimo left hidden"
python3 -c 'import sys, tomlkit
p = sys.argv[1]; doc = tomlkit.parse(open(p).read())
doc.setdefault("disabled_models", tomlkit.table())["stuck"] = doc["models"].pop("myalias")
open(p, "w").write(tomlkit.dumps(doc))' "${KIMI_CONFIG}"
rc=0
out=$("${KIMO}" kimi provider enable foo 2>&1) || rc=$?
check "rescue exits 0" 0 "${rc}"
check_contains "rescue reports the restored alias" "restored 1 model aliases left hidden" "${out}"
check "stuck alias is back in [models]" True "$(toml '"stuck" in doc["models"]')"
rc=0
"${KIMO}" kimi provider enable foo >/dev/null 2>&1 || rc=$?
check "enabling an enabled provider with nothing hidden still fails" 1 "${rc}"

echo "[3] sync: refreshed metadata, non-chat filter, prune"
FIXTURE="${HARNESS_ROOT}/models_fixture.py"
PORTS="${HARNESS_ROOT}/fixture.port"
MODELS_FILE="${HARNESS_ROOT}/models.json"
cat >"${FIXTURE}" <<'PY'
import http.server, sys

port_file, models_file = sys.argv[1], sys.argv[2]

class Models(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(models_file, "rb") as fh:
            data = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Models)
with open(port_file, "w", encoding="utf-8") as fh:
    fh.write(f"{server.server_port}\n")
server.serve_forever()
PY
echo '{"data":[{"id":"chat-a","context_length":8192},{"id":"text-embedding-3-small"},{"id":"whisper-1"}]}' >"${MODELS_FILE}"
harness_spawn python3 "${FIXTURE}" "${PORTS}" "${MODELS_FILE}"
tries=0
while [[ ! -s "${PORTS}" ]]; do
    if ((tries++ > 100)) || ! kill -0 "${HARNESS_LAST_PID}" 2>/dev/null; then
        bad "models fixture did not start"
        exit 1
    fi
    sleep 0.05
done
cat >"${KIMI_CONFIG}" <<EOF
[providers.live]
type = "openai"
base_url = "http://127.0.0.1:$(<"${PORTS}")/v1"
api_key = "sk-live"

[providers.nokey]
type = "openai"
base_url = "http://127.0.0.1:9/v1"
api_key_env = "KIMO_TEST_UNSET_KEY"

[models."live/whisper-1"]
provider = "live"
model = "whisper-1"
EOF

rc=0
out=$("${KIMO}" kimi provider sync --all --json 2>&1) || rc=$?
check "--all syncs every provider" 2 "$(jq '.results | length' <<<"${out}")"
check "a provider without its key is not a failure" 0 "${rc}"
check "nokey is reported as no-credential" no-credential \
    "$(jq -r '.results[] | select(.id == "nokey") | .status' <<<"${out}")"
check "non-chat models are filtered" 2 "$(jq -r '.results[] | select(.id == "live") | .filtered' <<<"${out}")"
check "the chat model is added" True "$(toml '"live/chat-a" in doc["models"]')"
check "no embedding alias is added" False "$(toml '"live/text-embedding-3-small" in doc["models"]')"

echo '{"data":[{"id":"chat-a","context_length":262144},{"id":"whisper-1"}]}' >"${MODELS_FILE}"
out=$("${KIMO}" kimi provider sync live --json 2>&1)
check "refreshed metadata counts as an update" 1 "$(jq -r '.updated' <<<"${out}")"
check "refreshed context size is written" 262144 "$(toml 'doc["models"]["live/chat-a"]["max_context_size"]')"
out=$("${KIMO}" kimi provider sync live --json 2>&1)
check "an unchanged catalog writes nothing" false "$(jq -r '.changed' <<<"${out}")"

out=$("${KIMO}" kimi provider sync live --prune --dry-run --json 2>&1)
check "dry-run prune would drop the earlier non-chat alias" 1 "$(jq -r '.removed' <<<"${out}")"
check "dry-run writes nothing" True "$(toml '"live/whisper-1" in doc["models"]')"
"${KIMO}" kimi provider sync live --prune >/dev/null 2>&1
check "prune drops the earlier non-chat alias" False "$(toml '"live/whisper-1" in doc["models"]')"
"${KIMO}" kimi provider sync live --include-nonchat >/dev/null 2>&1
check "--include-nonchat keeps non-chat models" True "$(toml '"live/whisper-1" in doc["models"]')"

echo "[4] Kalidroid preset sync"
KIMI_CONFIG="${HARNESS_ROOT}/kalidroid/config.toml"
mkdir -p "$(dirname "${KIMI_CONFIG}")"
KD_TOKEN="kd_ai_fixture-provider-sync"
out=$(KALIDROID_API_KEY="${KD_TOKEN}" KIMO_KALIDROID_BASE_URL="http://127.0.0.1:$(<"${PORTS}")/v1" \
    "${KIMO}" kimi provider sync kalidroid --json 2>&1)
check "Kalidroid preset sync succeeds" "ok" "$(jq -r '.results[] | select(.id == "kalidroid") | .status' <<<"${out}")"
check_contains "Kalidroid provider is added on first sync" "[providers.kalidroid]" "$(cat "${KIMI_CONFIG}")"
check "Kalidroid credential is referenced by name" "KALIDROID_API_KEY" "$(toml 'doc["providers"]["kalidroid"]["api_key_env"]')"
check "Kalidroid catalogue populates Kimi aliases" True "$(toml '"kalidroid/chat-a" in doc["models"]')"
check_not_contains "Kalidroid token is not written to config" "${KD_TOKEN}" "$(cat "${KIMI_CONFIG}")"

echo "[5] CLI errors"
for flag in --timeout --jobs; do
    rc=0
    out=$("${KIMO}" kimi provider sync "${flag}" 2>&1) || rc=$?
    check "${flag} without a value exits 1" 1 "${rc}"
    check_contains "${flag} without a value says so" "${flag} requires a value" "${out}"
    rc=0
    out=$("${KIMO}" kimi provider sync "${flag}" abc 2>&1) || rc=$?
    check "${flag} abc exits 1" 1 "${rc}"
    check_contains "${flag} abc names the problem" "positive whole number" "${out}"
done
rc=0
out=$("${KIMO}" kimi provider sync live --all 2>&1) || rc=$?
check "a name together with --all is rejected" 1 "${rc}"
rc=0
out=$("${KIMO}" kimi provider list --prune 2>&1) || rc=$?
check "sync-only options are rejected for list" 1 "${rc}"
rc=0
out=$("${KIMO}" kimi provider disable doesnotexist 2>&1) || rc=$?
check "disabling an unknown provider exits 1" 1 "${rc}"
check_contains "its error reaches stderr (not swallowed by the lock)" "provider 'doesnotexist' not found" "${out}"
rc=0
out=$("${KIMO}" kimi bogus 2>&1) || rc=$?
check "unknown kimi subcommand exits 1" 1 "${rc}"
check_not_contains "no bash 'return' error leaks out" "can only" "${out}"
check_contains "usage lists sync" "list|disable|enable|sync" "${out}"

harness_summary "kimi provider"
