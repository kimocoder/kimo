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
#   * claude gets the [1m] context suffix, CLAUDE_CODE_MAX_CONTEXT_TOKENS,
#     CLAUDE_CODE_SUBAGENT_MODEL and the ANTHROPIC_DEFAULT_*_MODEL tier overrides;
#     stale Codex subagent and family pins are stripped from ~/.claude/settings.json;
#     x-api-key stays unset so exactly one credential rides the request
#   * kimi: a validated key registers a named [providers.abliteration] (the key
#     by env-var NAME only) plus an alias per served model, and launches on
#     'abliteration/<id>'; when validation cannot complete (blocked network, no
#     tomlkit) kimi falls back to the zero-footprint KIMI_MODEL_* env channel
#     and NO config.toml is written; a rejected key (401/403) aborts the launch
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
    printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}"
    printf 'ANTHROPIC_DEFAULT_FABLE_MODEL=%s\n' "${ANTHROPIC_DEFAULT_FABLE_MODEL-<unset>}"
    printf 'CLAUDE_CODE_SUBAGENT_MODEL=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}"
    printf 'CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST=%s\n' "${CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST-<unset>}"
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
    printf 'ABLITERATION_API_KEY=%s\n' "${ABLITERATION_API_KEY-<unset>}"
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
    check "main model is the launched model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_MODEL)"
    check "opus tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
    check "sonnet tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
    check "haiku tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
    check "fable tier routed at the same model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_FABLE_MODEL)"
    check "subagents use the launched model" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" CLAUDE_CODE_SUBAGENT_MODEL)"
    check "claude is marked provider-managed" "1" "$(env_val "${CAPTURE}" CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST)"
    check "no Ollama host is exported" "<unset>" "$(env_val "${CAPTURE}" OLLAMA_HOST)"
fi

echo "[*] claude: stale Codex subagent and family pins are unpinned and overridden"
mkdir -p "${HOME}/.claude"
cat > "${HOME}/.claude/settings.json" << 'EOF'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(echo ok)"]},
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gpt-6.1-sol",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "gpt-6.1-sol",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gpt-6.1-sol",
    "ANTHROPIC_DEFAULT_FABLE_MODEL": "gpt-6.1-sol",
    "CLAUDE_CODE_SUBAGENT_MODEL": "gpt-6.1-sol",
    "KEEP_ME": "yes"
  }
}
EOF

ANTHROPIC_DEFAULT_OPUS_MODEL="gpt-6.1-sol" \
ANTHROPIC_DEFAULT_SONNET_MODEL="gpt-6.1-sol" \
ANTHROPIC_DEFAULT_HAIKU_MODEL="gpt-6.1-sol" \
ANTHROPIC_DEFAULT_FABLE_MODEL="gpt-6.1-sol" \
CLAUDE_CODE_SUBAGENT_MODEL="gpt-6.1-sol" \
launch claude --provider abliteration

check "subagents use the launched model instead of codex" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" CLAUDE_CODE_SUBAGENT_MODEL)"
check "opus tier uses the launched model instead of codex" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_OPUS_MODEL)"
check "sonnet tier uses the launched model instead of codex" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_SONNET_MODEL)"
check "haiku tier uses the launched model instead of codex" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
check "fable tier uses the launched model instead of codex" "abliterated-model-large-v2[1m]" "$(env_val "${CAPTURE}" ANTHROPIC_DEFAULT_FABLE_MODEL)"
check "settings keep the user's model choice" "opus" "$(python3 -c 'import json; print(json.load(open("'"${HOME}"'/.claude/settings.json"))["model"])')"
check "settings keep unrelated env" "yes" "$(python3 -c 'import json; print(json.load(open("'"${HOME}"'/.claude/settings.json"))["env"]["KEEP_ME"])')"
check "settings drop the Codex subagent pin" "absent" "$(python3 -c 'import json; env=json.load(open("'"${HOME}"'/.claude/settings.json")).get("env", {}); print("absent" if "CLAUDE_CODE_SUBAGENT_MODEL" not in env else env["CLAUDE_CODE_SUBAGENT_MODEL"])')"
check "settings drop the Codex opus pin" "absent" "$(python3 -c 'import json; env=json.load(open("'"${HOME}"'/.claude/settings.json")).get("env", {}); print("absent" if "ANTHROPIC_DEFAULT_OPUS_MODEL" not in env else env["ANTHROPIC_DEFAULT_OPUS_MODEL"])')"
check "settings drop the Codex fable pin" "absent" "$(python3 -c 'import json; env=json.load(open("'"${HOME}"'/.claude/settings.json")).get("env", {}); print("absent" if "ANTHROPIC_DEFAULT_FABLE_MODEL" not in env else env["ANTHROPIC_DEFAULT_FABLE_MODEL"])')"

echo "[*] claude: the image-capable model gets no 1M suffix"
launch claude --provider abliteration --model base
check "'base' resolves to abliterated-model" "abliterated-model" "$(flag_val "${CAPTURE}" --model)"
check "256K window exported" "262144" "$(env_val "${CAPTURE}" CLAUDE_CODE_MAX_CONTEXT_TOKENS)"

echo "[*] kimi: env-channel fallback when validation cannot complete"
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
# The harness curl stub refuses every non-loopback URL and logs the attempt.
# The one tolerated outbound call is the abliteration key validation against
# ${API}/v1/models (blocked here, so the launch falls back to the env channel);
# no Ollama endpoint may be contacted.
launch kimi --provider abliteration
blocked="$(harness_stub_calls curl)"
unexpected="$(grep -v "^curl BLOCKED ${API}/v1/models\$" <<<"${blocked}" | grep -v '^$' || true)"
if [[ -z "${unexpected}" ]]; then
    ok "the only outbound curl is the ${API}/v1/models validation (no /api/tags, /api/show or /api/ps)"
else
    bad "unexpected outbound curl: ${unexpected//$'\n'/; }"
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

echo "[*] kimi: a validated key registers the named provider and the served catalogue"
harness_fake_ollama --openai-models "abliterated-model,abliterated-model-large-v2,custom-served-model" \
    --openai-bearer "${KEY}"
export KIMO_ABLITERATION_BASE_URL="${FAKE_OLLAMA_URL}"
CFG="${HOME}/.kimi-code/config.toml"
rm -f "${CFG}"
launch kimi --provider abliteration
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake kimi was never exec'd on the validated path; cannot assert"
else
    check "kimi launches on the named alias" "abliteration/abliterated-model-large-v2" "$(flag_val "${CAPTURE}" -m)"
    check "the env channel is not used alongside the alias" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
    check "KIMI_MODEL_API_KEY stays unset" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
    check "ABLITERATION_API_KEY reaches kimi for the api_key_env reference" "${KEY}" "$(env_val "${CAPTURE}" ABLITERATION_API_KEY)"
fi
if [[ ! -f "${CFG}" ]]; then
    bad "the validated launch did not write ${CFG}"
else
    cfgtext="$(cat "${CFG}")"
    check_contains "the provider is registered under its real name" "[providers.abliteration]" "${cfgtext}"
    check_contains "the provider points at the OpenAI surface" "base_url = \"${FAKE_OLLAMA_URL}/v1\"" "${cfgtext}"
    check_contains "the credential is referenced by env-var name" 'api_key_env = "ABLITERATION_API_KEY"' "${cfgtext}"
    check_not_contains "the real key never lands in the config" "${KEY}" "${cfgtext}"
    check_contains "the launched model has an alias" '[models."abliteration/abliterated-model-large-v2"]' "${cfgtext}"
    check_contains "every served model is registered" '[models."abliteration/custom-served-model"]' "${cfgtext}"
    check_contains "the image-capable base model keeps image_in" "image_in" "${cfgtext}"
    check_contains "default_model is pinned to the launched alias" 'default_model = "abliteration/abliterated-model-large-v2"' "${cfgtext}"
fi
check_contains "the fixture served the validation call" "GET /v1/models" "$(cat "${FAKE_OLLAMA_LOG}")"

echo "[*] kimi: the ABLIT_KEY alias normalizes to ABLITERATION_API_KEY"
rm -f "${CAPTURE}" "${CFG}"
harness_reset_stub_log
env -u ABLITERATION_API_KEY ABLIT_KEY="${KEY}" "${KIMO}" launch kimi --provider abliteration >/dev/null 2>&1 || true
check "kimi still receives ABLITERATION_API_KEY" "${KEY}" "$(env_val "${CAPTURE}" ABLITERATION_API_KEY)"
check_contains "the config still names ABLITERATION_API_KEY" 'api_key_env = "ABLITERATION_API_KEY"' "$(cat "${CFG}")"

echo "[*] kimi: a rejected key aborts the launch"
harness_fake_ollama --openai-models "abliterated-model-large-v2" --openai-bearer "ak_somebody-elses-key"
export KIMO_ABLITERATION_BASE_URL="${FAKE_OLLAMA_URL}"
rm -f "${CAPTURE}" "${CFG}"
launch_out kimi --provider abliteration
check "a 401 exits non-zero" "1" "${LAUNCH_RC}"
check_contains "the rejection is reported" "rejected the API key" "${LAUNCH_OUT}"
if [[ -f "${CAPTURE}" ]]; then
    bad "a rejected key still exec'd kimi"
else
    ok "a rejected key never execs kimi"
fi
if [[ -e "${CFG}" ]]; then
    bad "a rejected key wrote a config"
else
    ok "a rejected key writes no config"
fi
unset KIMO_ABLITERATION_BASE_URL

echo
harness_summary "abliteration smoke"
