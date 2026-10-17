#!/usr/bin/env bash
# Launch contract shared by every external CLI:
#   * credentials: real OPENAI/ANTHROPIC/CURSOR keys reach only a plain local
#     daemon; remote/LAN hosts get the 'ollama' placeholder (codex, cursor,
#     cyberstrike, hermes, openclaw - the branches without their own scrub)
#   * argument passthrough: after 'launch <cli>', -v/--version/-h/--help/--json
#     go to the CLI, and everything after '--' is passed verbatim
#   * eviction: other models on the target host are unloaded only on request
#     (--evict / KIMO_LAUNCH_EVICT=always), never by default when non-interactive
#
# Usage: tests/launch_contract_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

WORK="$(mktemp -d)"
FAKE_DIR="${WORK}/bin"
CAPTURE="${WORK}/call.txt"
mkdir -p "${FAKE_DIR}"
export LAUNCH_CONTRACT_OUT="${CAPTURE}"

# One recorder serves every CLI name: argv, then the credential env.
for cli in claude codex cursor cyberstrike hermes openclaw; do
    cat > "${FAKE_DIR}/${cli}" <<'FAKE'
#!/usr/bin/env bash
# cyberstrike's 'provider add' pre-step must not overwrite the launch capture.
[[ "${1:-}" == "provider" ]] && exit 0
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY-<unset>}"
    printf 'ANTHROPIC_API_KEY=%s\n' "${ANTHROPIC_API_KEY-<unset>}"
    printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
    printf 'CURSOR_API_KEY=%s\n' "${CURSOR_API_KEY-<unset>}"
} > "${LAUNCH_CONTRACT_OUT:?}"
exit 0
FAKE
    chmod +x "${FAKE_DIR}/${cli}"
done
export PATH="${FAKE_DIR}:${PATH}"

LOCAL_HOST="http://127.0.0.1:9"       # loopback, unreachable
REMOTE_HOST="http://192.168.1.131:9"  # LAN address, blocked by the harness
SENTINEL="sk-REAL-SENTINEL-do-not-leak"

launch() { # <host> <cli> [args...]
    local host="$1" cli="$2"
    shift 2
    rm -f "${CAPTURE}"
    "${KIMO}" --host "${host}" launch "${cli}" --model kalidroid-27b:latest "$@" >/dev/null 2>&1 || true
}
argv_after_model() { # the CLI's argv minus kimo's own (first) --model pair
    awk '/^ARGV$/{a=1; next} /^ENV$/{exit} a' "${CAPTURE}" \
        | awk 'skip{skip=0; next} !done && $0=="--model"{skip=1; done=1; next} {print}' | paste -sd' ' -
}

echo "[*] credentials never leave the box"
export OPENAI_API_KEY="${SENTINEL}" ANTHROPIC_API_KEY="${SENTINEL}" \
    ANTHROPIC_AUTH_TOKEN="${SENTINEL}" CURSOR_API_KEY="${SENTINEL}"
for cli in codex cursor cyberstrike hermes openclaw; do
    launch "${REMOTE_HOST}" "${cli}"
    if [[ ! -f "${CAPTURE}" ]]; then
        bad "${cli}: fake CLI was never exec'd"
        continue
    fi
    check "${cli} remote: OPENAI_API_KEY scrubbed" "ollama" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
    check "${cli} remote: ANTHROPIC_API_KEY scrubbed" "ollama" "$(env_val "${CAPTURE}" ANTHROPIC_API_KEY)"
    check "${cli} remote: ANTHROPIC_AUTH_TOKEN unset" "<unset>" "$(env_val "${CAPTURE}" ANTHROPIC_AUTH_TOKEN)"
    check "${cli} remote: CURSOR_API_KEY unset" "<unset>" "$(env_val "${CAPTURE}" CURSOR_API_KEY)"
    launch "${LOCAL_HOST}" "${cli}"
    check "${cli} plain local: OPENAI_API_KEY kept" "${SENTINEL}" "$(env_val "${CAPTURE}" OPENAI_API_KEY)"
done
unset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CURSOR_API_KEY

echo "[*] child CLI flags are not swallowed by kimo"
launch "${LOCAL_HOST}" claude -p hi -v --json -h --version
check "-v/--json/-h/--version after 'launch <cli>' reach the CLI" "-p hi -v --json -h --version" "$(argv_after_model)"

launch "${LOCAL_HOST}" claude -- --model other -W --ctx 5 --evict
check "everything after -- reaches the CLI verbatim" "--model other -W --ctx 5 --evict" "$(argv_after_model)"

launch "${LOCAL_HOST}" claude -- -- literal
check "a second -- is passed through" "-- literal" "$(argv_after_model)"

check_match "global -v before the command still prints kimo's version" "^kimo v" "$("${KIMO}" -v)"
check_contains "'launch -h' still shows launch help" "kimo launch" "$("${KIMO}" launch -h)"
check_contains "launch help documents --" "Pass everything after it to the CLI untouched" "$("${KIMO}" launch --help)"

echo "[*] other loaded models are only evicted on request"
harness_fake_ollama --models "keep:latest,other:latest" --loaded "keep:latest,other:latest"
EVICT_LOG="${FAKE_OLLAMA_LOG}"
unloads() { grep -c '"keep_alive":0' "${EVICT_LOG}" || true; }

out=$("${KIMO}" --host "${FAKE_OLLAMA_URL}" launch claude --model keep:latest 2>&1 </dev/null) || true
check "non-interactive default unloads nothing" "0" "$(unloads)"
check_contains "non-interactive default says what it left loaded" "Leaving 1 other loaded model(s)" "${out}"

"${KIMO}" --host "${FAKE_OLLAMA_URL}" launch claude --model keep:latest --no-evict >/dev/null 2>&1 </dev/null || true
check "--no-evict unloads nothing" "0" "$(unloads)"

"${KIMO}" --host "${FAKE_OLLAMA_URL}" launch claude --model keep:latest --evict >/dev/null 2>&1 </dev/null || true
check "--evict unloads exactly the other model" "1" "$(unloads)"
check_contains "--evict unloads 'other', not the launched model" '"model":"other:latest"' "$(grep keep_alive "${EVICT_LOG}")"

KIMO_LAUNCH_EVICT=always "${KIMO}" --host "${FAKE_OLLAMA_URL}" launch claude --model keep:latest >/dev/null 2>&1 </dev/null || true
check "KIMO_LAUNCH_EVICT=always unloads too" "2" "$(unloads)"

echo "[*] --dry-run reports and stops"
export OPENAI_API_KEY="${SENTINEL}"
rm -f "${CAPTURE}"
out=$("${KIMO}" --host "${REMOTE_HOST}" launch codex --model m:latest --dry-run -- --foo 2>&1) || true
check "dry run does not start the CLI" "no" "$([[ -f "${CAPTURE}" ]] && echo yes || echo no)"
check_not_contains "dry run never prints a real key" "${SENTINEL}" "${out}"
check_contains "dry run shows the scrubbed key" "OPENAI_API_KEY ollama (placeholder)" "${out}"
check_contains "dry run shows the argv" "codex --oss --local-provider ollama --model m:latest --foo" "${out}"

json=$("${KIMO}" --json --host "${LOCAL_HOST}" launch claude --model m:latest --dry-run -- -p hi 2>/dev/null) || true
check "dry run --json argv" '["claude","--model","m:latest","-p","hi"]' "$(jq -c '.argv' <<<"${json}" 2>/dev/null || echo bad)"
check "dry run --json keeps a local key without printing it" "<kept: real value, plain local host>" \
    "$(jq -r '.env.OPENAI_API_KEY' <<<"${json}" 2>/dev/null || echo bad)"
check_not_contains "dry run --json never prints a real key" "${SENTINEL}" "${json}"
unset OPENAI_API_KEY

before=$(unloads)
"${KIMO}" --host "${FAKE_OLLAMA_URL}" launch claude --model keep:latest --evict --dry-run >/dev/null 2>&1 </dev/null || true
check "dry run never unloads, even with --evict" "${before}" "$(unloads)"

echo
harness_summary "launch contract"
