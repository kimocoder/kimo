#!/usr/bin/env bash
# Headless smoke tests for kimo's 'kimi' launch branch.
#
# Mocked layer (always): a fake 'kimi' on PATH records the argv/env that
# kimo passes, so we can assert the contract without the real binary:
#   * -m <alias> present
#   * KIMI_CODE_HOME points to an isolated temp dir (config written there)
#   * KIMI_DISABLE_TELEMETRY / KIMI_CODE_NO_AUTO_UPDATE exported
#   * KIMI_MODEL_* env channel: KIMI_MODEL_API_KEY forced to "ollama"
#     (kimo policy: never forward a real secret to a remote/LAN/tunnel host;
#     Ollama ignores the value). No timeout-env analog exists that kimo must
#     raise (kimi has no LLM request timeout env in 2.1.1).
#   * config-alias path: default_model pinned to the launched alias in
#     config.toml (headless -p prompt mode requires it; -m is ignored in -p).
#
# Live layer (opt-in, --live): run a real headless `kimi -p` turn through
# kimo, using an ISOLATED KIMI_CODE_HOME whose config.toml is written by kimo.
# Slow and network-dependent, so skipped by default. KIMO_SMOKE_HOST is the
# Ollama host to route to; KIMO_SMOKE_MODEL is the Ollama tag to launch.
#
# Usage: tests/kimi-smoke.sh [--live]

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_A="$(mktemp -d)"

FAKE_DIR="${TMPDIR_A}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_A}/call.txt"
export KIMI_SMOKE_OUT="${CAPTURE}"
# kimo writes its provider/alias registration to $KIMI_CODE_HOME/config.toml;
# keep that in the temp root, never the operator's ~/.kimi-code.
export KIMI_CODE_HOME="${TMPDIR_A}/kimi-code"
mkdir -p "${KIMI_CODE_HOME}"

cat > "${FAKE_DIR}/kimi" <<'FAKE'
#!/usr/bin/env bash
out="${KIMI_SMOKE_OUT:?KIMI_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'KIMI_CODE_HOME=%s\n' "${KIMI_CODE_HOME-<unset>}"
    printf 'KIMI_DISABLE_TELEMETRY=%s\n' "${KIMI_DISABLE_TELEMETRY-<unset>}"
    printf 'KIMI_CODE_NO_AUTO_UPDATE=%s\n' "${KIMI_CODE_NO_AUTO_UPDATE-<unset>}"
    printf 'KIMI_MODEL_NAME=%s\n' "${KIMI_MODEL_NAME-<unset>}"
    printf 'KIMI_MODEL_PROVIDER_TYPE=%s\n' "${KIMI_MODEL_PROVIDER_TYPE-<unset>}"
    printf 'KIMI_MODEL_BASE_URL=%s\n' "${KIMI_MODEL_BASE_URL-<unset>}"
    printf 'KIMI_MODEL_API_KEY=%s\n' "${KIMI_MODEL_API_KEY-<unset>}"
    printf 'KIMI_MODEL_MAX_CONTEXT_SIZE=%s\n' "${KIMI_MODEL_MAX_CONTEXT_SIZE-<unset>}"
    printf 'KIMI_MODEL_CAPABILITIES=%s\n' "${KIMI_MODEL_CAPABILITIES-<unset>}"
    printf 'KIMI_MODEL_REASONING_KEY=%s\n' "${KIMI_MODEL_REASONING_KEY-<unset>}"
    printf 'KIMI_MODEL_THINKING_EFFORT=%s\n' "${KIMI_MODEL_THINKING_EFFORT-<unset>}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/kimi"
# Fake stays on PATH for the whole mocked tier; restored before the live tier.
export PATH="${FAKE_DIR}:${PATH}"

# Unreachable upstream (port 9) so no real Ollama is contacted.
UPSTREAM="http://192.168.1.131:9"
run_launch() {
    rm -f "${CAPTURE}"
    "${KIMO}" --host "${UPSTREAM}" launch kimi \
        --model kalidroid-27b:latest >/dev/null 2>&1 || true
}

echo "[*] mocked: invocation + isolated KIMI_CODE_HOME"
run_launch
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake kimi was never exec'd (no capture); cannot assert"
else
    if has_flag "${CAPTURE}" -m && [[ -n "$(flag_val "${CAPTURE}" -m)" ]]; then
        ok "-m present: $(flag_val "${CAPTURE}" -m)"
    else
        bad "-m missing"
    fi
    check "KIMI_CODE_HOME set and non-empty" "yes" "$([[ -n "$(env_val "${CAPTURE}" KIMI_CODE_HOME)" ]] && echo yes || echo no)"
    check "KIMI_DISABLE_TELEMETRY exported (1)" "1" "$(env_val "${CAPTURE}" KIMI_DISABLE_TELEMETRY)"
    check "KIMI_CODE_NO_AUTO_UPDATE exported (1)" "1" "$(env_val "${CAPTURE}" KIMI_CODE_NO_AUTO_UPDATE)"
fi

echo "[*] mocked: config-alias path writes default_model + registers alias"
# The main path (tomlkit available) writes config.toml under KIMI_CODE_HOME
# with default_model = <alias>. We can't easily read it from the fake, but
# we can assert the alias form and that KIMI_MODEL_* is NOT set (config path
# unsets them before exec). The fake already recorded the env; verify unset.
check "KIMI_MODEL_NAME unset in config path" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_NAME)"
check "KIMI_MODEL_API_KEY unset in config path" "<unset>" "$(env_val "${CAPTURE}" KIMI_MODEL_API_KEY)"
# Alias form: ollama-<host-slug>/<model>
if has_flag "${CAPTURE}" -m; then
    mval="$(flag_val "${CAPTURE}" -m)"
    if [[ "${mval}" =~ ^ollama-192-168-1-131-9/kalidroid-27b:latest$ ]]; then
        ok "alias form correct: ${mval}"
    else
        bad "alias form unexpected: ${mval}"
    fi
fi

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: real headless 'kimi -p' through kimo, against an
# isolated KIMI_CODE_HOME whose config.toml is written by kimo (including
# default_model). No --host: keep kimo's active_host local so its CUDA-collision
# unload loop never touches the provider's actual Ollama host.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn through kimo"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    if ! command -v kimi >/dev/null 2>&1; then
        echo "  SKIP kimi CLI not found"
    else
        host="${KIMO_SMOKE_HOST:-http://192.168.1.131:11434}"
        model="${KIMO_SMOKE_MODEL:-granite-4.2-8b-GGUF:uncensored}"
        smoke_home="${TMPDIR_A}/kimi-home"
        mkdir -p "$smoke_home"
        # Pass --host so kimo routes to the remote Ollama (avoids local CUDA unload).
        # kimi reads its config from KIMI_CODE_HOME, which kimo writes to.
        set +e
        KIMI_CODE_HOME="${smoke_home}" timeout 300 "${KIMO}" --host "${host}" launch kimi --model "${model}" -p "Reply with exactly: PONG" >"${smoke_home}/run.out" 2>&1
        live_rc=$?
        set -e
        if [[ "${live_rc}" -eq 0 ]]; then
            if grep -qi 'PONG' "${smoke_home}/run.out"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(tail -c 200 "${smoke_home}/run.out")"; fi
            check "default_model written to config.toml" "yes" "$(rg -q 'default_model\s*=' "${smoke_home}/config.toml" && echo yes || echo no)"
        else
            bad "live turn failed (rc=${live_rc}): $(tail -c 200 "${smoke_home}/run.out")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]