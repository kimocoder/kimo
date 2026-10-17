#!/usr/bin/env bash
# Headless smoke tests for kimo's abliteration.ai cloud-provider routing
# ('launch --provider abliteration').
#
# Mocked layer (always): fake 'claude'/'kimi' binaries on PATH record the argv
# and env kimo passes, so the routing contract is asserted without a TUI and
# without any network call:
#   * base URLs point at api.abliteration.ai (Anthropic origin, OpenAI .../v1)
#   * the real ak_ key reaches the selected provider - the one deliberate
#     exception to kimo's non-local credential scrub - and never appears in
#     argv or in --dry-run output
#   * claude gets the [1m] context suffix, CLAUDE_CODE_MAX_CONTEXT_TOKENS and
#     the ANTHROPIC_DEFAULT_*_MODEL tier overrides; x-api-key stays unset so
#     exactly one credential rides the request
#   * kimi gets the zero-footprint KIMI_MODEL_* env channel and NO config.toml
#   * per-model capabilities and efforts: only 'abliterated-model' takes images
#     and it caps thinking effort at xhigh
#   * no Ollama probing: nothing contacts /api/tags, /api/show or /api/ps
#   * failures: missing key, unknown model, unsupported CLI, unknown provider
#   * provider precedence: flag > KIMO_CLOUD_PROVIDER > cloud_provider config
#   * '--provider ollama' still routes to a self-hosted daemon
#
# Usage: tests/abliteration-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

WORK="$(mktemp -d)"
FAKE_DIR="${WORK}/bin"
CAPTURE="${WORK}/call.txt"
mkdir -p "${FAKE_DIR}"
export ABLIT_SMOKE_OUT="${CAPTURE}"

# One recorder per CLI: argv, then every env var the routing contract covers.
cat > "${FAKE_DIR}/claude" <<'FAKE'
#!/usr/bin/env bash
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL-<unset>}"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-<unset>}"
    printf 'CLAUDE_CODE_MAX_CONTEXT_TOKENS=%s\n' "${CLAUDE_CODE_MAX_CONTEXT_TOKENS-<unset>}"
    printf 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW-<unset>}"
    printf 'CLAUDE_CODE_EFFORT_LEVEL=%s\n' "${CLAUDE_CODE_EFFORT_LEVEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-<unset>}"
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-<unset>}"
    printf 'OLLAMA_HOST=%s\n' "${OLLAMA_HOST-<unset>}"
} > "${ABLIT_SMOKE_OUT:?}"
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
    printf 'KIMI_MODEL_CAPABILITIES=%s\n' "${KIMI_MODEL_CAPABILITIES-<unset>}"
    printf 'KIMI_MODEL_REASONING_KEY=%s\n' "${KIMI_MODEL_REASONING_KEY-<unset>}"
    printf 'KIMI_MODEL_THINKING_EFFORT=%s\n' "${KIMI_MODEL_THINKING_EFFORT-<unset>}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-<unset>}"
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-<unset>}"
    printf 'OLLAMA_HOST=%s\n' "${OLLAMA_HOST-<unset>}"
} > "${ABLIT_SMOKE_OUT:?}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/claude" "${FAKE_DIR}/kimi"
export PATH="${FAKE_DIR}:${PATH}"

# A key-shaped sentinel: the tests assert it reaches the provider and that it is
# never echoed back to the user.
KEY="ak_TEST-SENTINEL-do-not-leak"
API="https://api.abliteration.ai"

# Exported once rather than prefixed per call: a 'VAR=x func' assignment can
# persist in the calling shell, which would silently satisfy the missing-key
# test below. The failure-path block unsets both spellings explicitly.
export ABLITERATION_API_KEY="${KEY}"
unset ABLIT_KEY

launch() { # <cli> [args...] ; leaves the CLI's capture in $CAPTURE
    rm -f "${CAPTURE}"
    harness_reset_stub_log
    "${KIMO}" launch "$@" >/dev/null 2>&1 || true
}
launch_out() { # <cli> [args...] ; sets LAUNCH_OUT / LAUNCH_RC
    rm -f "${CAPTURE}"
    harness_reset_stub_log
    LAUNCH_OUT="$("${KIMO}" launch "$@" 2>&1)" && LAUNCH_RC=0 || LAUNCH_RC=$?
}
argv_only() { # the CLI's recorded argv, joined
    awk '/^ARGV$/{a=1;next} /^ENV$/{exit} a' "${CAPTURE}" | paste -sd' ' -
}

echo "[*] claude: Anthropic surface routing"
launch claude --provider abliteration
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake claude was never exec'd (no capture); cannot assert"
else
    check "ANTHROPIC_BASE_URL is the API origin" "${API}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
    check "bearer token carries the real key" "${KEY}" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"
    check "x-api-key left unset (one credential per request)" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
    check "OPENAI_BASE_URL is the OpenAI surface" "${API}/v1" "$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
    check "claude model id gets the 1M context suffix" "abliterated-model-large-v2[1m]" "$(flag_val "${CAPTURE}" --model)"
    check "CLAUDE_CODE_MAX_CONTEXT_TOKENS is the model window" "1000000" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"
    check "opus tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
    check "sonnet tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
    check "haiku tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
    check "no Ollama host is exported" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
fi

echo "[*] claude: the image-capable model gets no 1M suffix"
launch claude --provider abliteration --model base
check "'base' resolves to abliterated-model" "abliterated-model" "$(flag_val "${CAPTURE}" --model)"
check "256K window exported" "262144" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"

echo "[*] kimi: zero-footprint env channel"
launch kimi --provider abliteration
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake kimi was never exec'd (no capture); cannot assert"
else
    check "provider type is openai" "openai" "$(env_val "${CAPTURE}" KIMI_MODEL_PROVIDER_TYPE)"
    check "base URL is the OpenAI surface" "${API}/v1" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
    check "model name is the canonical id" "abliterated-model-large-v2" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
    check "the real key rides the env channel" "${KEY}" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
    check "context size is the model window" "1000000" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
    check "text-only large model advertises no image_in" "tool_use,thinking" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
    check "reasoning key is abliteration's field" "reasoning_content" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
    check "default thinking effort is high" "high" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
    check "kimi takes no -m on the env channel" "" "$(argv_only)"
    check "no Ollama host is exported" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
fi
if [[ -e "${HOME}/.kimi-code/config.toml" ]]; then
    bad "kimi config.toml was written; the abliteration path must stay zero-footprint"
else
    ok "no ~/.kimi-code/config.toml written"
fi

echo "[*] kimi: per-model capabilities and effort ceiling"
launch kimi --provider abliteration --model abliterated-model
check "base model advertises image_in" "tool_use,thinking,image_in" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"

launch_out kimi --provider abliteration --model base --ctx 999999
check "--ctx above the window is capped" "262144" "$(env_val "${CAPTURE}" KIMI_MODEL_MAX_CONTEXT_SIZE)"
check_contains "--ctx cap is reported" "exceeds abliterated-model's window (262144)" "${LAUNCH_OUT}"

launch kimi --provider abliteration --model base
check "base model keeps a supported effort" "high" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"

launch_out kimi --provider abliteration --model base
KIMO_KIMI_EFFORT=max launch_out kimi --provider abliteration --model base
check "effort above the base model's ceiling falls back to xhigh" "xhigh" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check_contains "effort fallback is reported" "not offered by abliterated-model" "${LAUNCH_OUT}"

KIMO_KIMI_EFFORT=max launch kimi --provider abliteration --model abliterated-model-large-v2
check "large-v2 accepts max effort" "max" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"

echo "[*] ABLIT_KEY is accepted as an alias"
rm -f "${CAPTURE}"
harness_reset_stub_log
env -u ABLITERATION_API_KEY ABLIT_KEY="${KEY}" "${KIMO}" launch claude --provider abliteration >/dev/null 2>&1 || true
check "ABLIT_KEY supplies the bearer token" "${KEY}" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"

echo "[*] the key never reaches argv or the console"
launch claude --provider abliteration
out="$("${KIMO}" launch claude --provider abliteration 2>&1)" || true
check_not_contains "launch output never prints the key" "${KEY}" "${out}"
check_not_contains "argv never carries the key" "${KEY}" "$(argv_only)"

dry="$("${KIMO}" launch kimi --provider abliteration --dry-run 2>&1)" || true
check_not_contains "--dry-run never prints the key" "${KEY}" "${dry}"
check_contains "--dry-run masks it as kept" "ABLITERATION_API_KEY <kept: real value, abliteration.ai provider>" "${dry}"
check_contains "--dry-run reports the provider" "provider: abliteration" "${dry}"
check_contains "--dry-run reports the context window" "context: 1000000 tokens" "${dry}"

dry_json="$("${KIMO}" --json launch claude --provider abliteration --dry-run 2>/dev/null)" || true
check "dry-run --json names the provider" "abliteration" "$(jq -r '.provider' <<<"${dry_json}")"
check_not_contains "dry-run --json never prints the key" "${KEY}" "${dry_json}"

echo "[*] nothing probes an Ollama daemon or evicts a model"
# The harness curl stub refuses every non-loopback URL and logs the attempt, so
# an empty curl log means kimo contacted neither api.abliteration.ai nor a host.
launch kimi --provider abliteration
blocked="$(harness_stub_calls curl)"
if [[ -z "${blocked}" ]]; then
    ok "launch made no outbound curl call (no /api/tags, /api/show or /api/ps)"
else
    bad "unexpected outbound curl: ${blocked//$'\n'/; }"
fi

echo "[*] failure paths"
unset ABLITERATION_API_KEY ABLIT_KEY
launch_out claude --provider abliteration
check "missing key exits non-zero" "1" "${LAUNCH_RC}"
check_contains "missing key says which env var to set" "ABLITERATION_API_KEY" "${LAUNCH_OUT}"
if [[ -f "${CAPTURE}" ]]; then
    bad "missing key still exec'd the CLI"
else
    ok "missing key never execs the CLI"
fi

export ABLITERATION_API_KEY="${KEY}"
launch_out claude --provider abliteration --model kalidroid-27b:latest
check "unknown model exits non-zero" "1" "${LAUNCH_RC}"
check_contains "unknown model lists the catalogue" "abliterated-model-large-v2" "${LAUNCH_OUT}"

launch_out codex --provider abliteration
check "unsupported CLI exits non-zero" "1" "${LAUNCH_RC}"
check_contains "unsupported CLI names what is supported" "claude kimi" "${LAUNCH_OUT}"

launch_out claude --provider nosuchprovider
check "unknown provider exits non-zero" "1" "${LAUNCH_RC}"
check_contains "unknown provider names the valid ones" "ollama" "${LAUNCH_OUT}"

echo "[*] the Ollama per-CLI preset does not leak into the provider"
launch claude --provider abliteration
check "preset kalidroid tag is replaced by the provider default" "abliterated-model-large-v2[1m]" "$(flag_val "${CAPTURE}" --model)"

rm -f "${CAPTURE}"
KIMO_DEFAULT_MODEL="kalidroid-27b:latest" "${KIMO}" launch claude --provider abliteration >/dev/null 2>&1 || true
check "KIMO_DEFAULT_MODEL Ollama tag is ignored" "abliterated-model-large-v2[1m]" "$(flag_val "${CAPTURE}" --model)"

rm -f "${CAPTURE}"
KIMO_DEFAULT_MODEL="abliterated-model" "${KIMO}" launch claude --provider abliteration >/dev/null 2>&1 || true
check "a KIMO_DEFAULT_MODEL that is an abliteration id is honoured" "abliterated-model" "$(flag_val "${CAPTURE}" --model)"

rm -f "${CAPTURE}"
"${KIMO}" launch claude --provider abliteration --model large >/dev/null 2>&1 || true
check "an explicit --model still wins" "abliterated-model-large[1m]" "$(flag_val "${CAPTURE}" --model)"

echo "[*] provider selection precedence"
rm -f "${CAPTURE}"
KIMO_CLOUD_PROVIDER=abliteration "${KIMO}" launch claude >/dev/null 2>&1 || true
check "KIMO_CLOUD_PROVIDER selects the provider without a flag" "${API}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"

"${KIMO}" config set cloud_provider abliteration >/dev/null 2>&1
check "config set accepts cloud_provider=abliteration" "abliteration" "$("${KIMO}" config get cloud_provider)"
check_contains "config list shows the key" "cloud_provider" "$("${KIMO}" config 2>&1)"

rm -f "${CAPTURE}"
"${KIMO}" launch claude >/dev/null 2>&1 || true
check "the config default applies with no flag and no env" "${API}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"

launch_out claude --provider nosuchprovider
check "the flag is validated even when the config default is set" "1" "${LAUNCH_RC}"

rm -f "${CAPTURE}"
"${KIMO}" launch claude --provider ollama --model kalidroid-27b:latest >/dev/null 2>&1 || true
check "--provider ollama overrides the config default" "${OLLAMA_LOCAL_URL}" "$(env_val "${CAPTURE}" ANTHROPIC_BASE_URL)"
check "--provider ollama keeps the Ollama model tag" "kalidroid-27b:latest" "$(flag_val "${CAPTURE}" --model)"
"${KIMO}" config unset cloud_provider >/dev/null 2>&1

echo "[*] config validation"
cfgout="$("${KIMO}" config set cloud_provider bogus 2>&1)" && rc=0 || rc=1
check "config set rejects an unknown provider" "1" "${rc}"
check_contains "the rejection names the valid values" "abliteration" "${cfgout}"
check "the bogus value was not written" "" "$("${KIMO}" config get cloud_provider)"

echo
harness_summary "abliteration smoke"
