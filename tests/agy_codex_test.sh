#!/usr/bin/env bash
# Headless tests for 'kimo launch agy --provider codex'.
#
# agy speaks only Gemini. Codex models reach it through the loopback shim's
# Responses kind: the catalog slug is registered as a custom model, the shim
# holds CODEX_AUTH_TOKEN, and agy's own environment does not.
#
# The translation itself (headers, stream, store, tools) is covered by
# tests/gemini_shim_test.py. This file checks the launch wiring, including
# that the running shim advertises the catalog without calling ChatGPT.
#
# Usage: tests/agy_codex_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

FAKE_BIN="${HARNESS_ROOT}/agents"
CAPTURE="${HARNESS_ROOT}/agy-codex.txt"
LOG="${HARNESS_ROOT}/agy-codex.log"
mkdir -p "${FAKE_BIN}" "${HARNESS_ROOT}/codex-home"
export CODEX_HOME="${HARNESS_ROOT}/codex-home"
export AGY_SMOKE_CAPTURE="${CAPTURE}"
export AGY_SETTINGS="${HARNESS_ROOT}/agy-settings.json"
export KIMO_AGY_CLAIM_DIR="${HARNESS_ROOT}/agy-claims"
TOKEN="codex-oauth-fixture"

cat > "${CODEX_HOME}/models_cache.json" <<'JSON'
{
  "client_version": "9.9.9-test",
  "models": [
    {"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "context_window": 500000},
    {"slug": "gpt-6.1-terra", "display_name": "GPT-6.1 Terra", "visibility": "list", "context_window": 272000},
    {"slug": "hidden", "visibility": "hide"}
  ]
}
JSON

printf '{"model":"Old Model","trustedWorkspaces":["/x"]}' > "${AGY_SETTINGS}"

cat > "${FAKE_BIN}/agy" <<'SH'
#!/usr/bin/env bash
out="${AGY_SMOKE_CAPTURE:?}"
argv=("$@")
model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) model="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
base="${GOOGLE_GEMINI_BASE_URL-}"
models=""
if [[ -n "${base}" ]]; then
    models="$(curl -s -m 3 -H "x-goog-api-key: ${GEMINI_API_KEY-}" "${base}/v1beta/models" 2>/dev/null || true)"
fi
{
    printf 'ARGV\n'
    printf '%s\n' "${argv[@]}"
    printf 'ENV\n'
    for key in GOOGLE_GEMINI_BASE_URL GEMINI_API_KEY CODEX_AUTH_TOKEN CODEX_API_KEY CODEX_ACCESS_TOKEN \
        KIMO_SHIM_UPSTREAM_TOKEN KIMO_SHIM_CODEX; do
        printf '%s=%s\n' "${key}" "${!key-<unset>}"
    done
    printf 'MODELS=%s\n' "${models}"
    printf 'SETTINGS_MODELS=%s\n' "$(jq -r '(.customModelsConfig.customModels // {}) | keys | join(",")' "${AGY_SETTINGS}" 2>/dev/null)"
} > "${out}"
exit 0
SH
chmod +x "${FAKE_BIN}/agy"

echo "[*] [1] dry-run wires agy at the catalog slug"
dry=$(PATH="${FAKE_BIN}:${PATH}" CODEX_AUTH_TOKEN="${TOKEN}" "${KIMO}" launch agy --provider codex --dry-run)
check_contains "dry-run names codex" "provider: codex" "${dry}"
check_contains "dry-run model is the first catalog slug" "model  : gpt-6.1-sol" "${dry}"
check_contains "dry-run argv is agy --model" "agy --model gpt-6.1-sol" "${dry}"
check_contains "dry-run wire is gemini to responses" "wire   : gemini -> responses (loopback shim)" "${dry}"
check_contains "dry-run keeps the token in the shim" "loopback shim only, not exported to agy" "${dry}"
check_contains "dry-run host is the Codex backend" "chatgpt.com/backend-api/codex" "${dry}"

dry_explicit=$(PATH="${FAKE_BIN}:${PATH}" CODEX_AUTH_TOKEN="${TOKEN}" \
    "${KIMO}" launch agy --provider codex --model codex/gpt-6.1-terra --dry-run)
check_contains "an explicit codex/ slug is bare on the wire" "model  : gpt-6.1-terra" "${dry_explicit}"
check_contains "explicit argv keeps the bare slug" "agy --model gpt-6.1-terra" "${dry_explicit}"

echo "[*] [2] the metered platform is not wired for agy"
rc=0
err=$(PATH="${FAKE_BIN}:${PATH}" OPENAI_API_KEY="sk-fixture" \
    "${KIMO}" launch agy --provider openai --dry-run 2>&1) || rc=$?
check "agy --provider openai is rejected" 1 "${rc}"
check_contains "the rejection names the missing branch" "has no OpenAI launch branch" "${err}"

echo "[*] [3] a live launch registers the slug and hides the token"
rc=0
PATH="${FAKE_BIN}:${PATH}" CODEX_AUTH_TOKEN="${TOKEN}" \
    "${KIMO}" launch agy --provider codex >"${LOG}" 2>&1 || rc=$?
check "live codex launch exits 0" 0 "${rc}"
check "agy is launched with the catalog slug" "gpt-6.1-sol" "$(flag_val "${CAPTURE}" --model)"
check_match "agy points at a loopback shim" '^http://127\.0\.0\.1:[0-9]+$' "$(env_val "${CAPTURE}" GOOGLE_GEMINI_BASE_URL)"
check_contains "the shim lists the catalog" "models/gpt-6.1-sol" "$(env_val "${CAPTURE}" MODELS)"
check_contains "the shim lists the other catalog slug" "models/gpt-6.1-terra" "$(env_val "${CAPTURE}" MODELS)"
check_not_contains "a hidden catalog row is not advertised" "models/hidden" "$(env_val "${CAPTURE}" MODELS)"
check "settings registered the launched slug" "gpt-6.1-sol" "$(env_val "${CAPTURE}" SETTINGS_MODELS)"
check "agy never receives CODEX_AUTH_TOKEN" "<unset>" "$(env_val "${CAPTURE}" CODEX_AUTH_TOKEN)"
check "agy never receives CODEX_API_KEY" "<unset>" "$(env_val "${CAPTURE}" CODEX_API_KEY)"
check "agy never receives CODEX_ACCESS_TOKEN" "<unset>" "$(env_val "${CAPTURE}" CODEX_ACCESS_TOKEN)"
check "agy never receives the shim upstream token" "<unset>" "$(env_val "${CAPTURE}" KIMO_SHIM_UPSTREAM_TOKEN)"
check "agy never receives the codex shim flag" "<unset>" "$(env_val "${CAPTURE}" KIMO_SHIM_CODEX)"
check_contains "the launcher says responses" "responses wire" "$(cat "${LOG}")"
want="$(printf '%s' '{"model":"Old Model","trustedWorkspaces":["/x"]}' | jq -cS .)"
got="$(jq -cS . "${AGY_SETTINGS}" 2>/dev/null || true)"
check "agy settings are restored after the session" "${want}" "${got}"

port="$(env_val "${CAPTURE}" GOOGLE_GEMINI_BASE_URL)"
if curl -sf -m 2 "${port}/healthz" >/dev/null 2>&1; then
    bad "shim still listening on ${port} after kimo exit"
else
    ok "shim stopped after kimo exit"
fi

echo "[*] [4] an explicit slug is what agy is launched with"
rc=0
PATH="${FAKE_BIN}:${PATH}" CODEX_AUTH_TOKEN="${TOKEN}" \
    "${KIMO}" launch agy --provider codex --model codex/gpt-6.1-terra >"${LOG}" 2>&1 || rc=$?
check "explicit live launch exits 0" 0 "${rc}"
check "explicit model reaches agy" "gpt-6.1-terra" "$(flag_val "${CAPTURE}" --model)"
check "settings registered the explicit slug" "gpt-6.1-terra" "$(env_val "${CAPTURE}" SETTINGS_MODELS)"
check "the token is still withheld" "<unset>" "$(env_val "${CAPTURE}" CODEX_AUTH_TOKEN)"
got="$(jq -cS . "${AGY_SETTINGS}" 2>/dev/null || true)"
check "settings are restored after the explicit launch" "${want}" "${got}"

echo
harness_summary "agy_codex"
