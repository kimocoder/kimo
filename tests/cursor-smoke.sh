#!/usr/bin/env bash
# Headless smoke tests for kimo's 'cursor' launch branch.
#
# Mocked layer (always): a fake 'cursor' (and 'cursor-agent') on PATH records
# the argv/env that kimo passes, so we can assert the invocation contract
# without launching the TUI:
#   * --model present and CURSOR_MODEL carries the resolved model
#   * CURSOR_API_ENDPOINT / CURSOR_API_BASE_URL / CURSOR_LOCAL_AGENT_BASE_URL
#     point at <active_host>/v1 and follow --remote
#   * user-set CURSOR_API_ENDPOINT is honoured; OPENAI_API_KEY defaults to
#     'ollama'
#   * binary fallback: 'cursor-agent' is exec'd when 'cursor' is absent
#
# Live layer (opt-in, --live): if a real cursor CLI and a reachable Ollama host
# are available, run a headless -p turn and require a sane answer. Slow and
# network-dependent, so it is skipped by default.
#
# Usage: tests/cursor-smoke.sh [--live]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_C="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_C}"; }
trap cleanup EXIT

FAKE_DIR="${TMPDIR_C}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_C}/call.txt"
export CURSOR_SMOKE_OUT="${CAPTURE}"

make_fake() { # <binary-name>
    cat > "${FAKE_DIR}/$1" <<'FAKE'
#!/usr/bin/env bash
out="${CURSOR_SMOKE_OUT:?CURSOR_SMOKE_OUT unset}"
{
    printf 'BIN=%s\n' "$(basename "$0")"
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'CURSOR_API_ENDPOINT=%s\n' "${CURSOR_API_ENDPOINT-}"
    printf 'CURSOR_API_BASE_URL=%s\n' "${CURSOR_API_BASE_URL-}"
    printf 'CURSOR_LOCAL_AGENT_BASE_URL=%s\n' "${CURSOR_LOCAL_AGENT_BASE_URL-}"
    printf 'CURSOR_MODEL=%s\n' "${CURSOR_MODEL-}"
    printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL-}"
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-}"
} > "${out}"
exit 0
FAKE
    chmod +x "${FAKE_DIR}/$1"
}
make_fake cursor

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

# Run kimo's cursor launcher against a fake CLI and capture what it passed.
# Host ports are deliberately unassigned (9) so no real Ollama is contacted and
# no live model gets unloaded as a launch side effect. PATH is restricted to
# the fake dir plus system dirs and HOME is a throwaway dir, because kimo
# prepends ~/.local/bin (and other per-CLI bin dirs) to PATH itself — a real
# cursor/cursor-agent/agent install would otherwise shadow the fakes.
# /usr/local/bin is kept at the END: kimo prepends it only when absent, so
# having it present (but last) keeps the fake dir first.
FAKE_HOME="${TMPDIR_C}/home"
mkdir -p "${FAKE_HOME}"
run_launch() { # <host-mode-args...> ; sets CAPTURE
    rm -f "${CAPTURE}"
    env -u CURSOR_BIN_DIR HOME="${FAKE_HOME}" PATH="${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
        "${KIMO}" "$@" launch cursor --model kalidroid-27b:latest \
        >/dev/null 2>&1 || true
}
LOCAL_HOST="http://127.0.0.1:9"          # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"     # LAN address, unreachable

echo "[*] mocked: invocation contract"
run_launch --host "${LOCAL_HOST}"
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake cursor was never exec'd (no capture); cannot assert"
else
    check "cursor binary exec'd" "cursor" "$(env_val "${CAPTURE}" BIN)"
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    check "CURSOR_MODEL is resolved model" "kalidroid-27b:latest" "$(env_val "${CAPTURE}" CURSOR_MODEL)"
    check "CURSOR_API_ENDPOINT is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" CURSOR_API_ENDPOINT)"
    check "CURSOR_API_BASE_URL is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" CURSOR_API_BASE_URL)"
    check "CURSOR_LOCAL_AGENT_BASE_URL is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" CURSOR_LOCAL_AGENT_BASE_URL)"
    bs="$(env_val "${CAPTURE}" OPENAI_BASE_URL)"
    [[ "${bs}" == */v1 ]] && ok "OPENAI_BASE_URL ends in /v1 (${bs})" || bad "OPENAI_BASE_URL not /v1: '${bs}'"
fi

echo "[*] mocked: remote host routing"
( export OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "CURSOR_API_ENDPOINT follows remote host" "${REMOTE_HOST}/v1" "$(env_val "${CAPTURE}" CURSOR_API_ENDPOINT)"
check "CURSOR_LOCAL_AGENT_BASE_URL follows remote host" "${REMOTE_HOST}/v1" "$(env_val "${CAPTURE}" CURSOR_LOCAL_AGENT_BASE_URL)"

echo "[*] mocked: user overrides honoured"
CURSOR_API_ENDPOINT="http://example.internal:9/v1" run_launch --host "${LOCAL_HOST}"
check "existing CURSOR_API_ENDPOINT is honoured" "http://example.internal:9/v1" "$(env_val "${CAPTURE}" CURSOR_API_ENDPOINT)"
( unset OPENAI_API_KEY; run_launch --host "${LOCAL_HOST}" )
check "OPENAI_API_KEY defaults to ollama" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"

echo "[*] mocked: binary fallback"
rm -f "${FAKE_DIR}/cursor"
make_fake cursor-agent
# The fallback only triggers when no 'cursor' binary exists anywhere in the
# PATH kimo enforces (it force-includes /usr/local/bin). On machines with a
# real cursor install the fallback is unreachable, so skip rather than fail.
if env HOME="${FAKE_HOME}" PATH="${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
        bash -c 'command -v cursor' >/dev/null 2>&1; then
    echo "  SKIP real 'cursor' present in kimo's enforced PATH; fallback unreachable here"
else
    run_launch --host "${LOCAL_HOST}"
    check "falls back to cursor-agent" "cursor-agent" "$(env_val "${CAPTURE}" BIN)"
fi

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: requires a real cursor CLI.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn"
    real_cursor="$(PATH="${PATH}" command -v cursor || PATH="${PATH}" command -v cursor-agent || true)"
    host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
    model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
    if [[ -z "${real_cursor}" ]]; then
        echo "  SKIP cursor CLI not found"
    elif ! curl -s -m 3 "${host}/api/tags" >/dev/null 2>&1; then
        echo "  SKIP no Ollama at ${host}"
    else
        out="${TMPDIR_C}/live.txt"
        if CURSOR_API_ENDPOINT="${host}/v1" CURSOR_API_BASE_URL="${host}/v1" \
                CURSOR_LOCAL_AGENT_BASE_URL="${host}/v1" CURSOR_MODEL="${model}" \
                OPENAI_API_KEY=ollama timeout 300 "${real_cursor}" \
                --model "${model}" -p 'Reply with exactly: PONG' >"${out}" 2>&1; then
            if grep -qi 'PONG' "${out}"; then ok "live answer contains PONG"; else bad "live answer lacked PONG: $(head -c 200 "${out}")"; fi
        else
            bad "live turn failed (rc=$?): $(head -c 200 "${out}")"
        fi
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
