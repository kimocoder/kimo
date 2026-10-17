#!/usr/bin/env bash
# Headless smoke tests for kimo's 'agy' (Google Antigravity) launch branch.
#
# Mocked layer (always): a fake 'agy' on PATH records the argv/env that kimo
# passes, plus a snapshot of the shim and settings it set up, so we can assert
# the contract without the real TUI:
#   * --model present
#   * GOOGLE_GEMINI_BASE_URL points at a live loopback shim (kernel port)
#   * the shim answers /healthz, and is reaped when kimo exits
#   * settings.json is patched for the session (modelProvider=gemini +
#     customModelsConfig.customModels[<model>]) and restored on exit
#   * GEMINI_API_KEY is NOT scrubbed - it only ever reaches the localhost shim,
#     whose upstream requests carry no auth (unlike qwen/claude)
#
# The real shim is started (it is local and reaped), but AGY_SETTINGS is pointed
# at a temp file so the user's real settings.json is never touched.
#
# Live layer (opt-in, --live): run a real headless agy turn through kimo
# (kimo launch agy --model <m> -p ... --output-format json) and require a sane
# answer. Slow and network-dependent, so it is skipped by default.
#
# Usage: tests/agy-smoke.sh [--live]

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
SETTINGS="${TMPDIR_A}/settings.json"
export AGY_SMOKE_OUT="${CAPTURE}"
export AGY_SETTINGS="${SETTINGS}"
export KIMO_AGY_CLAIM_DIR="${TMPDIR_A}/claims"

# Original settings content that the launch must restore verbatim.
printf '{"model":"Old Model","trustedWorkspaces":["/x"]}' > "${SETTINGS}"

cat > "${FAKE_DIR}/agy" <<'FAKE'
#!/usr/bin/env bash
out="${AGY_SMOKE_OUT:?AGY_SMOKE_OUT unset}"
base="${GOOGLE_GEMINI_BASE_URL-}"
code=""
[[ -n "${base}" ]] && code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "${base}/healthz" 2>/dev/null || true)"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'GEMINI_API_KEY=%s\n' "${GEMINI_API_KEY-<unset>}"
    printf 'GOOGLE_GEMINI_BASE_URL=%s\n' "${base-<unset>}"
    printf 'SHIM_HEALTHZ=%s\n' "${code}"
    printf 'SETTINGS_PROVIDER=%s\n' "$(jq -r '.modelProvider // "<none>"' "${AGY_SETTINGS}" 2>/dev/null)"
    printf 'SETTINGS_MODELS=%s\n' "$(jq -r '(.customModelsConfig.customModels // {}) | keys | join(",")' "${AGY_SETTINGS}" 2>/dev/null)"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/agy"

# Unreachable upstream (port 9) so no real Ollama is contacted; the shim only
# connects upstream when a request is actually proxied.
UPSTREAM="http://192.168.1.131:9"
run_launch() {
    rm -f "${CAPTURE}"
    printf '{"model":"Old Model","trustedWorkspaces":["/x"]}' > "${SETTINGS}"
    PATH="${FAKE_DIR}:${PATH}" "${KIMO}" --host "${UPSTREAM}" launch agy \
        --model kalidroid-27b:latest >/dev/null 2>&1 || true
}

echo "[*] mocked: invocation + shim contract"
run_launch
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake agy was never exec'd (no capture); cannot assert"
else
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    shim_base="$(env_val "${CAPTURE}" GOOGLE_GEMINI_BASE_URL)"
    if [[ "${shim_base}" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then
        ok "GOOGLE_GEMINI_BASE_URL is a loopback shim (${shim_base})"
    else
        bad "GOOGLE_GEMINI_BASE_URL is not a loopback shim: '${shim_base}'"
    fi
    check "shim /healthz answered" "200" "$(env_val "${CAPTURE}" SHIM_HEALTHZ)"
    check "settings modelProvider patched to gemini" "gemini" "$(env_val "${CAPTURE}" SETTINGS_PROVIDER)"
    if [[ ",$(env_val "${CAPTURE}" SETTINGS_MODELS)," == *",kalidroid-27b:latest,"* ]]; then
        ok "settings customModels contains the launched model"
    else
        bad "settings customModels missing the launched model: '$(env_val "${CAPTURE}" SETTINGS_MODELS)'"
    fi

    # Cleanup: shim reaped and settings restored once kimo exits.
    port="${shim_base##*:}"
    if curl -sf -m 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
        bad "shim still listening on ${port} after kimo exit"
    else
        ok "shim stopped after kimo exit"
    fi
    want="$(printf '%s' '{"model":"Old Model","trustedWorkspaces":["/x"]}' | jq -cS .)"
    got="$(jq -cS . "${SETTINGS}" 2>/dev/null || true)"
    if [[ "${got}" == "${want}" ]]; then
        ok "settings.json restored on exit"
    else
        bad "settings.json not restored: got '${got}', want '${want}'"
    fi
fi

echo "[*] mocked: GEMINI_API_KEY passthrough (no scrub needed)"
unset GEMINI_API_KEY 2>/dev/null || true
run_launch
check "GEMINI_API_KEY defaults to ollama" "ollama" "$(env_val "${CAPTURE}" GEMINI_API_KEY)"

GEMINI_API_KEY="g-key-REAL" run_launch
check "GEMINI_API_KEY passes through (only reaches localhost shim)" "g-key-REAL" "$(env_val "${CAPTURE}" GEMINI_API_KEY)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: real agy, full kimo path (shim + settings), headless -p.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn through kimo"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    if ! command -v agy >/dev/null 2>&1; then
        echo "  SKIP agy CLI not found"
    else
        host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
        model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
        # The live path must patch the user's real settings, so do not override
        # AGY_SETTINGS here; AGY_SETTINGS is exported above for the mocked tier.
        out="${TMPDIR_A}/live.txt"
        if unset AGY_SETTINGS; \
                timeout 300 "${KIMO}" --host "${host}" launch agy --model "${model}" \
                -p 'Reply with exactly: PONG' --output-format json >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(head -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(head -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
