#!/usr/bin/env bash
# Headless smoke tests for kimo's 'grok' launch branch.
#
# Mocked layer (always): a fake 'grok' on PATH records the argv/env that kimo
# passes, so we can assert the invocation contract without launching the TUI:
#   * --model present, GROK_MODELS_BASE_URL points at <active_host>/v1
#   * XAI_API_KEY is forced to 'ollama' for every host (a real key is never
#     forwarded - grok sends it as a Bearer token to GROK_MODELS_BASE_URL)
#   * grok's exit code is propagated (kimo runs grok, it does not exec it)
#   * --ctx patches context_window into the grok config while grok runs and
#     reverts it on exit
#
# Live layer (opt-in, --live): if a real 'grok' and a reachable Ollama host are
# available, run a headless -p turn and require a sane answer. Slow and
# network-dependent, so it is skipped by default.
#
# Usage: tests/grok-smoke.sh [--live]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_G="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_G}"; }
trap cleanup EXIT

FAKE_DIR="${TMPDIR_G}/bin"
mkdir -p "${FAKE_DIR}"
CAPTURE="${TMPDIR_G}/call.txt"
export GROK_SMOKE_OUT="${CAPTURE}"

FAKE_GROK_RC=0
write_fake_grok() {
    cat > "${FAKE_DIR}/grok" <<'FAKE'
#!/usr/bin/env bash
out="${GROK_SMOKE_OUT:?GROK_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'GROK_MODELS_BASE_URL=%s\n' "${GROK_MODELS_BASE_URL-}"
    printf 'XAI_API_KEY=%s\n' "${XAI_API_KEY-}"
    printf 'CONFIG_BEGIN\n'
    if [[ -n "${GROK_SMOKE_CONFIG-}" && -f "${GROK_SMOKE_CONFIG-}" ]]; then
        cat "${GROK_SMOKE_CONFIG}"
    fi
    printf 'CONFIG_END\n'
} > "${out}"
exit "${GROK_SMOKE_FAKE_RC:-0}"
FAKE
    chmod +x "${FAKE_DIR}/grok"
}
write_fake_grok

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

# Run kimo's grok launcher against a fake CLI and capture what it passed.
# Host ports are deliberately unassigned (9) so no real Ollama is contacted and
# no live model gets unloaded as a launch side effect. PATH is restricted to
# the fake dir plus system dirs and HOME is a throwaway dir, because kimo
# prepends ~/.grok/bin (and other per-CLI bin dirs) to PATH itself — a real
# grok install would otherwise shadow the fake. /usr/local/bin is kept at the
# END: kimo prepends it only when absent, so having it present (but last)
# keeps the fake dir first.
FAKE_HOME="${TMPDIR_G}/home"
mkdir -p "${FAKE_HOME}"
run_launch() { # <host-mode-args...> ; sets CAPTURE
    rm -f "${CAPTURE}"
    env HOME="${FAKE_HOME}" PATH="${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
        KIMO_GROK_CLAIM_DIR="${TMPDIR_G}/claims" \
        "${KIMO}" "$@" launch grok --model kalidroid-27b:latest \
        >/dev/null 2>&1 || true
}
LOCAL_HOST="http://127.0.0.1:9"          # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"     # LAN address, unreachable

SENTINEL="xai-REAL-SENTINEL-do-not-leak"

echo "[*] mocked: invocation contract"
run_launch --host "${LOCAL_HOST}"
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake grok was never run (no capture); cannot assert"
else
    if has_flag "${CAPTURE}" --model && [[ -n "$(flag_val "${CAPTURE}" --model)" ]]; then
        ok "--model present: $(flag_val "${CAPTURE}" --model)"
    else
        bad "--model missing"
    fi
    check "GROK_MODELS_BASE_URL is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" GROK_MODELS_BASE_URL)"
fi

echo "[*] mocked: remote host routing"
( export OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "GROK_MODELS_BASE_URL follows remote host" "${REMOTE_HOST}/v1" "$(env_val "${CAPTURE}" GROK_MODELS_BASE_URL)"

echo "[*] mocked: api-key scrub (forced, all hosts)"
( export XAI_API_KEY="${SENTINEL}"; run_launch --host "${LOCAL_HOST}" )
check "plain local host still forces XAI_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" XAI_API_KEY)"

( export XAI_API_KEY="${SENTINEL}" OLLAMA_REMOTE_URL="${REMOTE_HOST}"; run_launch --remote )
check "remote host forces XAI_API_KEY to ollama" "ollama" "$(env_val "${CAPTURE}" XAI_API_KEY)"

echo "[*] mocked: exit code propagation"
rm -f "${CAPTURE}"
rc=0
env HOME="${FAKE_HOME}" PATH="${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
    KIMO_GROK_CLAIM_DIR="${TMPDIR_G}/claims" GROK_SMOKE_FAKE_RC=42 \
    "${KIMO}" --host "${LOCAL_HOST}" launch grok --model kalidroid-27b:latest \
    >/dev/null 2>&1 || rc=$?
check "grok exit code 42 is propagated" "42" "${rc}"

echo "[*] mocked: context_window patch and revert"
GROK_CFG="${TMPDIR_G}/config.toml"
printf 'default_model = "grok-code-fast-1"\n' > "${GROK_CFG}"
GROK_CFG_BEFORE="$(cat "${GROK_CFG}")"
export GROK_SMOKE_CONFIG="${GROK_CFG}"
env HOME="${FAKE_HOME}" PATH="${FAKE_DIR}:/usr/bin:/bin:/usr/local/bin" \
    KIMO_GROK_CLAIM_DIR="${TMPDIR_G}/claims" GROK_CONFIG="${GROK_CFG}" \
    "${KIMO}" --host "${LOCAL_HOST}" launch grok --model kalidroid-27b:latest --ctx 8192 \
    >/dev/null 2>&1 || true
if [[ -f "${CAPTURE}" ]] && grep -q 'context_window = 8192' "${CAPTURE}"; then
    ok "context_window=8192 visible to grok while running"
else
    bad "context_window=8192 not in config during run: $(sed -n '/CONFIG_BEGIN/,/CONFIG_END/p' "${CAPTURE}" 2>/dev/null | head -5)"
fi
if grep -q 'context_window' "${GROK_CFG}"; then
    bad "context_window override leaked into config after exit: $(cat "${GROK_CFG}")"
else
    ok "config reverted on exit"
fi
[[ "$(cat "${GROK_CFG}")" == "${GROK_CFG_BEFORE}" ]] \
    && ok "pre-existing config content preserved" \
    || bad "config content changed: $(cat "${GROK_CFG}")"
unset GROK_SMOKE_CONFIG

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# ---------------------------------------------------------------------------
# Optional live turn: requires the real grok CLI.
# ---------------------------------------------------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: headless -p turn"
    real_grok="$(PATH="${PATH}" command -v grok || true)"
    host="${KIMO_SMOKE_HOST:-http://127.0.0.1:11434}"
    model="${KIMO_SMOKE_MODEL:-kalidroid-27b:latest}"
    if [[ -z "${real_grok}" ]]; then
        echo "  SKIP grok CLI not found"
    elif ! curl -s -m 3 "${host}/api/tags" >/dev/null 2>&1; then
        echo "  SKIP no Ollama at ${host}"
    else
        out="${TMPDIR_G}/live.txt"
        if GROK_MODELS_BASE_URL="${host}/v1" XAI_API_KEY=ollama timeout 300 "${real_grok}" \
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
