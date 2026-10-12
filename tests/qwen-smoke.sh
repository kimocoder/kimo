#!/usr/bin/env bash
# Headless smoke tests for kimo's 'qwen' launch branch.
#
# Mocked layer (always): a fake 'qwen' on PATH records the argv/env that kimo
# passes, so we can assert the invocation contract without launching the TUI:
#   * --openai-base-url <host>/v1, --auth-type openai, --model present
#   * --openai-api-key is scrubbed to 'ollama' for non-plain-local hosts, and
#     only forwards a real OPENAI_API_KEY to a plain local loopback daemon
#   * QWEN_CODE_API_TIMEOUT_MS is exported (unless the user set one)
#
# Live layer (opt-in, --live): if a real 'qwen' and a reachable Ollama host are
# available, run a headless -p turn and require a sane JSON/text answer. Slow
# and network-dependent, so it is skipped by default.
#
# Usage: tests/qwen-smoke.sh [--live]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_Q="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_Q}"; }
trap cleanup EXIT

FAKE_DIR="${TMPDIR_Q}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_Q}/call.txt"
export QWEN_SMOKE_OUT="${CAPTURE}"

cat > "${FAKE_DIR}/qwen" <<'FAKE'
#!/usr/bin/env bash
out="${QWEN_SMOKE_OUT:?QWEN_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-}"
    printf 'QWEN_CODE_API_TIMEOUT_MS=%s\n' "${QWEN_CODE_API_TIMEOUT_MS-}"
} > "${out}"
exit 0
FAKE
chmod +x "${FAKE_DIR}/qwen"

pass=0 fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}

# Extract the value following a flag from the captured argv, or the env value.
flag_val() { awk -v f="$2" '$0==f{getline; print; exit}' "$1"; }
has_flag() { awk -v f="$2" '$0==f{found=1} END{exit !found}' "$1"; }
env_val()  { sed -n "s/^$2=//p" "$1" | head -n1; }

# Run kimo's qwen launcher against a fake CLI and capture what it passed.
# Host ports are deliberately unassigned (9) so no real Ollama is contacted and
# no live model gets unloaded as a launch side effect.
run_launch() { # <host-mode-args...> ; sets CAPTURE
    rm -f "${CAPTURE}"
    PATH="${FAKE_DIR}:${PATH}" "${KIMO}" "$@" launch qwen --model kalidroid-27b:latest \
        >/dev/null 2>&1 || true
}
LOCAL_HOST="http://127.0.0.1:9"          # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"     # LAN address, unreachable
TUNNEL_HOST="http://127.0.0.1:11438"     # ssh -L tunnel (loopback but off-box)

SENTINEL="sk-REAL-SENTINEL-do-not-leak"
export OPENAI_API_KEY="${SENTINEL}"

echo "[*] mocked: invocation contract"
run_launch --host "${LOCAL_HOST}"
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake qwen was never exec'd (no capture); cannot assert"
else
    ok "--openai-base-url present: $(flag_val "${CAPTURE}" --openai-base-url)"
    check "--auth-type is openai" "openai" "$(flag_val "${CAPTURE}" --auth-type)"
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    bs="$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
    [[ "${bs}" == */v1 ]] && ok "OPENAI_BASE_URL ends in /v1 (${bs})" || bad "OPENAI_BASE_URL not /v1: '${bs}'"
fi

echo "[*] mocked: api-key scrub"
run_launch --host "${LOCAL_HOST}"
check "plain local host forwards the real key" "${SENTINEL}" "$(flag_val "${CAPTURE}" --openai-api-key)"
check "plain local host env keeps the real key" "${SENTINEL}" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"

( export OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "remote host scrubs --openai-api-key to ollama" "ollama" "$(flag_val "${CAPTURE}" --openai-api-key)"
check "remote host scrubs env OPENAI_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"

run_launch --host "${REMOTE_HOST}"
check "LAN host scrubs --openai-api-key to ollama" "ollama" "$(flag_val "${CAPTURE}" --openai-api-key)"

run_launch --host "${TUNNEL_HOST}"
check "ssh -L tunnel host scrubs --openai-api-key to ollama" "ollama" "$(flag_val "${CAPTURE}" --openai-api-key)"

echo "[*] mocked: request timeout default"
run_launch --host "${LOCAL_HOST}"
check "QWEN_CODE_API_TIMEOUT_MS default" "600000" "$(env_val "${CAPTURE}" QWEN_CODE_API_TIMEOUT_MS)"

QWEN_CODE_API_TIMEOUT_MS=123456 run_launch --host "${LOCAL_HOST}"
check "existing QWEN_CODE_API_TIMEOUT_MS is honoured" "123456" "$(env_val "${CAPTURE}" QWEN_CODE_API_TIMEOUT_MS)"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: requires the real qwen CLI.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn"
    real_qwen="$(PATH="${PATH}" command -v qwen || true)"
    host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
    model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
    if [[ -z "${real_qwen}" ]]; then
        echo "  SKIP qwen CLI not found"
    elif ! curl -s -m 3 "${host}/api/tags" >/dev/null 2>&1; then
        echo "  SKIP no Ollama at ${host}"
    else
        out="${TMPDIR_Q}/live.json"
        if QWEN_CODE_API_TIMEOUT_MS=600000 timeout 300 "${real_qwen}" \
                --openai-base-url "${host}/v1" --openai-api-key ollama \
                --auth-type openai --model "${model}" \
                -p 'Reply with exactly: PONG' -o json >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(head -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(head -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
