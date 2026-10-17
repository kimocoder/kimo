#!/usr/bin/env bash
# Headless smoke tests for kimo's 'codex' launch branch.
#
# Mocked layer (always): a fake 'codex' on PATH records the argv/env that kimo
# passes, so we can assert the invocation contract without launching the TUI:
#   * --oss and --local-provider ollama flags, --model present
#   * CODEX_OSS_BASE_URL points at <active_host>/v1
#   * OPENAI_BASE_URL ends in /v1 and OPENAI_API_KEY defaults to 'ollama'
#
# Live layer (opt-in, --live): if a real 'codex' and a reachable Ollama host are
# available, run a headless 'codex exec' turn and require a sane answer. Slow
# and network-dependent, so it is skipped by default.
#
# Usage: tests/codex-smoke.sh [--live]

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_C="$(mktemp -d)"

FAKE_DIR="${TMPDIR_C}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_C}/call.txt"
export CODEX_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/codex" <<'FAKE'
#!/usr/bin/env bash
out="${CODEX_SMOKE_OUT:?CODEX_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'CODEX_OSS_BASE_URL=%s\n' "${CODEX_OSS_BASE_URL-}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-}"
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/codex"

# Run kimo's codex launcher against a fake CLI and capture what it passed.
# Host ports are deliberately unassigned (9) so no real Ollama is contacted and
# no live model gets unloaded as a launch side effect.
run_launch() { # <host-mode-args...> ; sets CAPTURE
    rm -f "${CAPTURE}"
    PATH="${FAKE_DIR}:${PATH}" "${KIMO}" "$@" launch codex --model kalidroid-27b:latest \
        >/dev/null 2>&1 || true
}
LOCAL_HOST="http://127.0.0.1:9"          # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"     # LAN address, unreachable

echo "[*] mocked: invocation contract"
run_launch --host "${LOCAL_HOST}"
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake codex was never exec'd (no capture); cannot assert"
else
    has_flag "${CAPTURE}" --oss && ok "--oss present" || bad "--oss missing"
    check "--local-provider is ollama" "ollama" "$(flag_val "${CAPTURE}" --local-provider)"
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    check "CODEX_OSS_BASE_URL is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" CODEX_OSS_BASE_URL)"
    bs="$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
    [[ "${bs}" == */v1 ]] && ok "OPENAI_BASE_URL ends in /v1 (${bs})" || bad "OPENAI_BASE_URL not /v1: '${bs}'"
fi

echo "[*] mocked: remote host routing"
( export OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "CODEX_OSS_BASE_URL follows remote host" "${REMOTE_HOST}/v1" "$(env_val "${CAPTURE}" CODEX_OSS_BASE_URL)"

echo "[*] mocked: api-key default"
( unset OPENAI_API_KEY; run_launch --host "${LOCAL_HOST}" )
check "OPENAI_API_KEY defaults to ollama" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: requires the real codex CLI.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless exec turn"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    real_codex="$(PATH="${PATH}" command -v codex || true)"
    host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
    model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
    if [[ -z "${real_codex}" ]]; then
        echo "  SKIP codex CLI not found"
    elif ! curl -s -m 3 "${host}/api/tags" >/dev/null 2>&1; then
        echo "  SKIP no Ollama at ${host}"
    else
        out="${TMPDIR_C}/live.txt"
        if CODEX_OSS_BASE_URL="${host}/v1" OPENAI_API_KEY=ollama timeout 300 "${real_codex}" \
                exec --oss --local-provider ollama --model "${model}" \
                'Reply with exactly: PONG' >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(head -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(head -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
