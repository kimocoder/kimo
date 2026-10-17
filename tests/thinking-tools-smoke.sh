#!/usr/bin/env bash
# Headless checks for kimo's thinking/tools capability handling.
#
# Part A - unit checks of _kimi_model_spec (extracted from kimo, curl stubbed):
#   * Ollama capabilities map thinking->thinking, tools->tool_use,
#     vision->image_in
#   * thinking models get support_efforts/off_effort/reasoning_key/default
#     effort; non-thinking models get none of them
#   * a failed /api/show probe falls back to tool_use only
#   * explicit overrides (caps/efforts/effort/off/reasoning_key/ctx) win over
#     probed values; ctx precedence is flag > runtime num_ctx > arch maximum
#
# Part B - launch-branch integration (fake kimi CLI + stubbed curl, env
# channel forced via an invalid-TOML KIMI_CONFIG):
#   * thinking model exports KIMI_MODEL_CAPABILITIES with thinking+tool_use,
#     KIMI_MODEL_REASONING_KEY and KIMI_MODEL_THINKING_EFFORT
#   * non-thinking model gets neither reasoning var - even when stale values
#     are exported by the caller (kimi would fail the request outright)
#   * KIMO_KIMI_EFFORT / KIMO_KIMI_REASONING_KEY / KIMO_KIMI_CAPABILITIES
#     overrides are honoured
#
# Usage: tests/thinking-tools-smoke.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

TMPDIR_T="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Part A: _kimi_model_spec unit checks
# ---------------------------------------------------------------------------
echo "[*] unit: _kimi_model_spec capability mapping"

SPEC_SRC="${TMPDIR_T}/spec.sh"
awk '/^_kimi_model_spec\(\)/,/^}/' "${KIMO}" > "${SPEC_SRC}"
grep -q '_kimi_model_spec()' "${SPEC_SRC}" || { echo "FATAL: could not extract _kimi_model_spec"; exit 1; }

STUB_BIN="${TMPDIR_T}/stubbin"
mkdir -p "${STUB_BIN}"

# Canned /api/show responses keyed by model name; everything else gets {}.
cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
url="" body=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) body="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[[ "${url}" == */api/show ]] || { printf '{}'; exit 0; }
case "${body}" in
    *thinker*)  printf '%s' '{"capabilities":["thinking","tools"],"parameters":"num_ctx 8192","model_info":{"llama.context_length":131072}}' ;;
    *plain*)    printf '%s' '{"capabilities":["tools"],"parameters":"num_ctx 4096","model_info":{"llama.context_length":32768}}' ;;
    *visionary*) printf '%s' '{"capabilities":["vision","tools"],"model_info":{"llama.context_length":8192}}' ;;
    *)          exit 1 ;;  # probe failure
esac
STUB
chmod +x "${STUB_BIN}/curl"

spec_for() { # <model> [overrides: ctx caps efforts deff off rkey]
    local model="$1"; shift
    PATH="${STUB_BIN}:/usr/bin:/bin" bash -c '
        source "$1"; shift
        _kimi_model_spec "http://127.0.0.1:9" "ollama-test" "$@"
    ' _ "${SPEC_SRC}" "${model}" "$@"
}
jqv() { jq -r ".$2" <<<"$1"; }

spec="$(spec_for thinker:latest)"
check "thinking maps to thinking" "thinking,tool_use" "$(jqv "${spec}" caps)"
check "thinking sets efforts" "low,medium,high,xhigh,max" "$(jqv "${spec}" efforts)"
check "thinking sets off_effort" "none" "$(jqv "${spec}" off)"
check "thinking sets reasoning_key" "reasoning" "$(jqv "${spec}" rkey)"
check "thinking sets default effort" "high" "$(jqv "${spec}" deff)"
check "runtime num_ctx wins over arch max" "8192" "$(jqv "${spec}" ctx)"

spec="$(spec_for plain:latest)"
check "tools-only maps to tool_use" "tool_use" "$(jqv "${spec}" caps)"
check "non-thinking has no efforts" "" "$(jqv "${spec}" efforts)"
check "non-thinking has no off_effort" "" "$(jqv "${spec}" off)"
check "non-thinking has no reasoning_key" "" "$(jqv "${spec}" rkey)"
check "non-thinking has no default effort" "" "$(jqv "${spec}" deff)"

spec="$(spec_for visionary:latest)"
check "vision maps to image_in" "image_in,tool_use" "$(jqv "${spec}" caps)"
check "arch max used when no runtime num_ctx" "8192" "$(jqv "${spec}" ctx)"

spec="$(spec_for unknown:latest)"
check "failed probe falls back to tool_use" "tool_use" "$(jqv "${spec}" caps)"
check "failed probe yields no thinking fields" "" "$(jqv "${spec}" rkey)"

echo "[*] unit: _kimi_model_spec overrides"
spec="$(spec_for plain:latest "" "thinking,tool_use")"
check "cap override beats probe" "thinking,tool_use" "$(jqv "${spec}" caps)"
check "cap override enables thinking fields" "reasoning" "$(jqv "${spec}" rkey)"

spec="$(spec_for thinker:latest "" "" "low,high" "xhigh" "off" "reasoning_content")"
check "efforts override" "low,high" "$(jqv "${spec}" efforts)"
check "default effort override" "xhigh" "$(jqv "${spec}" deff)"
check "off effort override" "off" "$(jqv "${spec}" off)"
check "reasoning_key override" "reasoning_content" "$(jqv "${spec}" rkey)"

spec="$(spec_for thinker:latest "2048")"
check "ctx override beats runtime num_ctx" "2048" "$(jqv "${spec}" ctx)"

# ---------------------------------------------------------------------------
# Part B: launch-branch env channel (thinking vs non-thinking)
# ---------------------------------------------------------------------------
echo "[*] launch: env channel capability wiring"

FAKE_DIR="${TMPDIR_T}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_T}/call.txt"
export TT_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/kimi" <<'FAKE'
#!/usr/bin/env bash
out="${TT_SMOKE_OUT:?TT_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'KIMI_MODEL_NAME=%s\n' "${KIMI_MODEL_NAME-__UNSET__}"
    printf 'KIMI_MODEL_CAPABILITIES=%s\n' "${KIMI_MODEL_CAPABILITIES-__UNSET__}"
    printf 'KIMI_MODEL_REASONING_KEY=%s\n' "${KIMI_MODEL_REASONING_KEY-__UNSET__}"
    printf 'KIMI_MODEL_THINKING_EFFORT=%s\n' "${KIMI_MODEL_THINKING_EFFORT-__UNSET__}"
    printf 'KIMI_MODEL_BASE_URL=%s\n' "${KIMI_MODEL_BASE_URL-__UNSET__}"
    printf 'KIMI_MODEL_API_KEY=%s\n' "${KIMI_MODEL_API_KEY-__UNSET__}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/kimi"

# Same isolation as the cursor/grok suites: kimo prepends per-CLI bin dirs
# (e.g. ~/.kimi-code/bin) and /usr/local/bin to PATH itself, so a real kimi
# install would shadow the fake. /usr/local/bin stays at the END - kimo only
# prepends it when absent.
FAKE_HOME="${TMPDIR_T}/home"
mkdir -p "${FAKE_HOME}"

# Invalid TOML forces kimi_register_all_models to fail rc=4, so the launch
# falls back to the KIMI_MODEL_* env channel under test.
BROKEN_CONFIG="${TMPDIR_T}/config.toml"
printf '[broken\n' > "${BROKEN_CONFIG}"

run_launch() { # <model> [extra env as K=V...]
    rm -f "${CAPTURE}"
    local model="$1"; shift
    env HOME="${FAKE_HOME}" PATH="${STUB_BIN}:${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
        KIMI_CONFIG="${BROKEN_CONFIG}" KIMO_KIMI_CONFIG_LOCK="${TMPDIR_T}/kimi.lock" \
        "$@" \
        "${KIMO}" --host http://127.0.0.1:9 launch kimi --model "${model}" \
        >/dev/null 2>&1 || true
}

run_launch thinker:latest
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake kimi was never exec'd (no capture); cannot assert"
else
    check "thinking model caps" "thinking,tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
    check "thinking model reasoning key" "reasoning" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
    check "thinking model default effort" "high" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
    check "env model name" "thinker:latest" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
    check "env base url is host/v1" "http://127.0.0.1:9/v1" "$(env_val "${CAPTURE}" KIMI_MODEL_BASE_URL)"
fi

run_launch plain:latest
check "non-thinking model caps" "tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "non-thinking model: no reasoning key" "__UNSET__" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "non-thinking model: no thinking effort" "__UNSET__" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"

echo "[*] launch: stale inherited effort is scrubbed on non-thinking models"
run_launch plain:latest KIMI_MODEL_REASONING_KEY=reasoning KIMI_MODEL_THINKING_EFFORT=low
check "stale reasoning key removed" "__UNSET__" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"
check "stale thinking effort removed" "__UNSET__" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"

echo "[*] launch: overrides honoured"
run_launch thinker:latest KIMO_KIMI_EFFORT=xhigh KIMO_KIMI_REASONING_KEY=reasoning_content
check "KIMO_KIMI_EFFORT override" "xhigh" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"
check "KIMO_KIMI_REASONING_KEY override" "reasoning_content" "$(env_val "${CAPTURE}" KIMI_MODEL_REASONING_KEY)"

run_launch plain:latest KIMO_KIMI_CAPABILITIES=thinking,tool_use
check "KIMO_KIMI_CAPABILITIES override beats probe" "thinking,tool_use" "$(env_val "${CAPTURE}" KIMI_MODEL_CAPABILITIES)"
check "cap override enables thinking effort" "high" "$(env_val "${CAPTURE}" KIMI_MODEL_THINKING_EFFORT)"

echo
echo "thinking/tools checks: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
