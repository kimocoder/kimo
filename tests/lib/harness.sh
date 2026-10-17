# shellcheck shell=bash
# tests/lib/harness.sh - hermetic environment + shared assertions for kimo tests.
#
# Source it first thing in a test, before any mktemp or $HOME use:
#
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#
# What it isolates (all under one private temp root, removed on exit):
#   * HOME, XDG_{CONFIG,CACHE,DATA,STATE}_HOME, XDG_RUNTIME_DIR and TMPDIR, so
#     kimo and the CLIs it drives never read or write the operator's real
#     ~/.config/kimo, ~/.kimi-code, ~/.grok, settings.json, claim dirs or locks.
#   * kimo's own system paths: config file, Apache token file, proxy render
#     script and tunings store point into the temp root.
#   * Ollama endpoints: local and remote point at dead addresses, so no test
#     reaches the operator's daemon or the ssh tunnel (and no launch unloads a
#     live model). Tests that need a daemon start tests/lib/fake_ollama.py.
#     The WebBridge URL is dead too, so no test drives a real browser.
#   * Network: http(s)_proxy points at a dead loopback port with loopback in
#     no_proxy. Python urllib and curl therefore reach loopback fixtures
#     only; anything else fails fast like an unreachable host.
#   * PATH stubs, recorded in $HARNESS_STUB_LOG: systemctl, service,
#     apache2ctl, sudo, ssh, ollama, npm, npx, pip, pip3, pipx, apt, apt-get,
#     wget, and a loopback-only curl, so 'curl ... | bash' installers fetch nothing.
#   * Ambient KIMO_*, OLLAMA_* and provider credential variables are cleared.
#
# Assertions record failures in a file as well as in the pass/fail counters,
# so a failure inside a subshell still fails the run. The EXIT trap forces a
# non-zero status if any assertion failed, even if the test forgot to check.
#
# Live tiers (--live) are opt-in and deliberately non-hermetic: call
# harness_use_real_env first to get the real HOME, PATH, proxies and keys back.
#
# Knobs (set in the environment before sourcing):
#   HARNESS_KEEP=1   keep the temp root after the run and print its path.

if [[ -n "${HARNESS_ROOT:-}" && "${HARNESS_MAIN_BASHPID:-}" == "${BASHPID}" ]]; then
    return 0
fi

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # consumed by the tests that source this file
HARNESS_REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
HARNESS_MAIN_BASHPID="${BASHPID}"

# Snapshot the real environment (in memory only: it may hold credentials)
# before anything is changed, so harness_use_real_env can restore it.
HARNESS_REAL_ENV="$(export -p)"
HARNESS_REAL_PATH="${PATH}"
HARNESS_REAL_CURL="$(type -P curl || true)"
# HOME moves, which would hide user-site packages such as tomlkit; keep the
# real user base readable so kimo's optional Python deps still import.
HARNESS_PYTHONUSERBASE="$(python3 -c 'import site; print(site.getuserbase())' 2>/dev/null || true)"

HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kimo-test.XXXXXX")"
chmod 700 "${HARNESS_ROOT}"
HARNESS_STUB_DIR="${HARNESS_ROOT}/stubs"
HARNESS_STUB_LOG="${HARNESS_ROOT}/stub-calls.log"
HARNESS_FAILURES="${HARNESS_ROOT}/failures"
HARNESS_EXIT_HOOKS=()
HARNESS_BG_PIDS=()
mkdir -p "${HARNESS_STUB_DIR}" "${HARNESS_ROOT}"/{home,config,cache,data,state,runtime,tmp,etc}
chmod 700 "${HARNESS_ROOT}/runtime"
: >"${HARNESS_STUB_LOG}"
: >"${HARNESS_FAILURES}"

# Variables the harness sets; harness_use_real_env unsets them again.
HARNESS_MANAGED_VARS=(
    HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR TMPDIR
    PATH PYTHONUSERBASE PYTHONDONTWRITEBYTECODE
    http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    KIMO_NO_AUTOSCAN KIMO_CONFIG_FILE KIMO_TOKEN_FILE KIMO_PROXY_RENDER_SCRIPT
    KIMO_PUBLIC_DOMAIN KIMO_TUNINGS_FILE KIMO_WEBBRIDGE_URL KIMO_OLLAMA_MODELS OLLAMA_LOCAL_URL OLLAMA_REMOTE_URL
    HARNESS_STUB_LOG HARNESS_REAL_CURL
)

_harness_scrub_env() {
    local name
    while IFS= read -r name; do
        case "${name}" in
            KIMO_*|OM_*|OLLAMA_*|KIMI_*|GROK_*|AGY_*|CURSOR_*|CYBERSTRIKE_*|CLAUDE_CODE_*|QWEN_*|CODEX_*|OPENCODE_*) ;;
            ANTHROPIC_*|OPENAI_*|GEMINI_*|GOOGLE_*|XAI_*|OPENROUTER_*|DASHSCOPE_*|MOONSHOT_*|ALIBABA_*) ;;
            ABLITERATION_*|ABLIT_*) ;;
            GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN|API_TIMEOUT_MS|API_BASE) ;;
            *) continue ;;
        esac
        unset "${name}"
    done < <(compgen -e)
}
_harness_scrub_env

export HOME="${HARNESS_ROOT}/home"
export XDG_CONFIG_HOME="${HARNESS_ROOT}/config"
export XDG_CACHE_HOME="${HARNESS_ROOT}/cache"
export XDG_DATA_HOME="${HARNESS_ROOT}/data"
export XDG_STATE_HOME="${HARNESS_ROOT}/state"
export XDG_RUNTIME_DIR="${HARNESS_ROOT}/runtime"
export TMPDIR="${HARNESS_ROOT}/tmp"
[[ -n "${HARNESS_PYTHONUSERBASE}" ]] && export PYTHONUSERBASE="${HARNESS_PYTHONUSERBASE}"
export PYTHONDONTWRITEBYTECODE=1

# Dead proxy (discard port) for everything that is not loopback.
export http_proxy="http://127.0.0.1:9" https_proxy="http://127.0.0.1:9"
export HTTP_PROXY="${http_proxy}" HTTPS_PROXY="${https_proxy}"
export all_proxy="${http_proxy}" ALL_PROXY="${http_proxy}"
export no_proxy="127.0.0.1,localhost,::1" NO_PROXY="127.0.0.1,localhost,::1"

export KIMO_NO_AUTOSCAN=1
export KIMO_CONFIG_FILE="${XDG_CONFIG_HOME}/kimo/config"
export KIMO_TOKEN_FILE="${HARNESS_ROOT}/etc/ollama-api.token"
export KIMO_PROXY_RENDER_SCRIPT="${HARNESS_STUB_DIR}/render-ollama-proxy.sh"
export KIMO_PUBLIC_DOMAIN="kimo-test.invalid"
export KIMO_TUNINGS_FILE="${HARNESS_ROOT}/etc/tunings.json"
# Distinct dead endpoints: a loopback port nothing listens on for "local" and
# a non-loopback name (blocked by the proxy) for "remote". Setting the remote
# URL also stops kimo from probing the real ssh tunnel on 127.0.0.1:11438.
export OLLAMA_LOCAL_URL="http://127.0.0.1:1"
export OLLAMA_REMOTE_URL="http://remote.kimo-test.invalid:11434"
# A running WebBridge daemon would otherwise open tabs in the operator's real
# browser during 'web url' / 'web search' tests.
export KIMO_WEBBRIDGE_URL="http://127.0.0.1:1/command"
# 'sync' reads source blobs from a local model store; when this is set, no
# other store (~/.ollama, /usr/share/ollama, ...) is looked at.
export KIMO_OLLAMA_MODELS="${HARNESS_ROOT}/ollama-models"
mkdir -p "${KIMO_OLLAMA_MODELS}"
export HARNESS_STUB_LOG HARNESS_REAL_CURL

# -----------------------------------------------------------------------------
# PATH stubs
# -----------------------------------------------------------------------------
# A stub logs "<name> <args>" to $HARNESS_STUB_LOG and exits with
# $HARNESS_STUB_RC_<name> (non-alphanumerics -> _), else its default.
_harness_write_stub() { # <name> <default-rc> [stderr message]
    local name="$1" rc="$2" msg="${3:-}" var
    var="HARNESS_STUB_RC_${name//[^A-Za-z0-9_]/_}"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# kimo test harness stub: records the call and touches nothing.\n'
        printf 'printf "%%s\\n" "%s${*:+ $*}" >>"${HARNESS_STUB_LOG:?}"\n' "${name}"
        [[ -n "${msg}" ]] && printf 'echo "%s: %s" >&2\n' "${name}" "${msg}"
        printf 'exit "${%s:-%s}"\n' "${var}" "${rc}"
    } >"${HARNESS_STUB_DIR}/${name}"
    chmod 755 "${HARNESS_STUB_DIR}/${name}"
}

for _harness_name in service apache2ctl render-ollama-proxy.sh; do
    _harness_write_stub "${_harness_name}" 0
done
for _harness_name in npm npx pip pip3 pipx apt apt-get; do
    _harness_write_stub "${_harness_name}" 1 "blocked by the kimo test harness"
done
_harness_write_stub sudo 1 "privilege escalation blocked by the kimo test harness"
_harness_write_stub ssh 255 "connections blocked by the kimo test harness"
_harness_write_stub wget 4 "network access blocked by the kimo test harness"
unset _harness_name

# systemctl: services report inactive unless HARNESS_STUB_SYSTEMCTL_ACTIVE=0,
# so nothing is reloaded by default; every other verb succeeds.
cat >"${HARNESS_STUB_DIR}/systemctl" <<'STUB'
#!/usr/bin/env bash
# kimo test harness stub: records the call and touches nothing.
printf '%s\n' "systemctl $*" >>"${HARNESS_STUB_LOG:?}"
for arg in "$@"; do
    case "${arg}" in
        is-active|is-enabled|is-failed) exit "${HARNESS_STUB_SYSTEMCTL_ACTIVE:-3}" ;;
    esac
done
exit "${HARNESS_STUB_RC_systemctl:-0}"
STUB

# ollama: an empty model list, and no daemon or registry is contacted.
cat >"${HARNESS_STUB_DIR}/ollama" <<'STUB'
#!/usr/bin/env bash
# kimo test harness stub: records the call and touches nothing.
printf '%s\n' "ollama $*" >>"${HARNESS_STUB_LOG:?}"
case "${1:-}" in
    list|ls) printf 'NAME    ID    SIZE    MODIFIED\n' ;;
    -v|--version|version) printf 'ollama version is 0.0.0-harness\n' ;;
esac
exit "${HARNESS_STUB_RC_ollama:-0}"
STUB

# curl: loopback URLs go to the real curl (fixture servers); any other URL is
# refused like an unreachable host (exit 7), so 'curl ... | bash' installers,
# registries and LAN hosts are never fetched. Option values are skipped so a
# URL inside a -d JSON payload is not mistaken for the request target.
cat >"${HARNESS_STUB_DIR}/curl" <<'STUB'
#!/usr/bin/env bash
# kimo test harness stub: loopback-only curl.
blocked=""
check_url() {
    local rest="${1#*://}" host
    rest="${rest#*@}"
    if [[ "${rest}" == \[* ]]; then
        host="${rest#[}"; host="${host%%]*}"
    else
        host="${rest%%[:/?#]*}"
    fi
    case "${host}" in
        127.*|localhost|::1|0.0.0.0) ;;
        *) blocked="$1" ;;
    esac
}
takes_value='^-(d|H|o|w|K|X|m|u|A|e|F|b|c|x|T|r|C|E|U|Y|y|z|t|Q|P)$|^--(data|data-[a-z]+|json|header|output|write-out|config|request|max-time|connect-timeout|user|user-agent|referer|form|form-string|cookie|cookie-jar|resolve|connect-to|proxy|proxy-user|upload-file|range|continue-at|retry|retry-delay|retry-max-time|cacert|capath|cert|key|cert-type|key-type|interface|limit-rate|max-filesize|output-dir|unix-socket|abstract-unix-socket|dns-servers|expect100-timeout|keepalive-time|noproxy|oauth2-bearer|pinnedpubkey|stderr|trace|trace-ascii|variable|url-query|aws-sigv4)$'
skip_next=false
for arg in "$@"; do
    if ${skip_next}; then
        skip_next=false
        continue
    fi
    case "${arg}" in
        --url=*) check_url "${arg#--url=}" ;;
        --*=*) ;;
        --url) ;;
        -*)
            if [[ "${arg}" =~ ${takes_value} ]]; then
                skip_next=true
            elif [[ "${arg}" =~ ^-[a-zA-Z]+$ && "${arg: -1}" =~ [dHowKXmuAeFbcxTrCEUYyztQP] ]]; then
                skip_next=true
            fi
            ;;
        *://*) check_url "${arg}" ;;
    esac
done
if [[ -n "${blocked}" ]]; then
    printf '%s\n' "curl BLOCKED ${blocked}" >>"${HARNESS_STUB_LOG:?}"
    echo "curl: (7) blocked by the kimo test harness (non-loopback URL: ${blocked})" >&2
    exit 7
fi
[[ -n "${HARNESS_REAL_CURL:-}" ]] || { echo "curl: real curl not found" >&2; exit 2; }
exec "${HARNESS_REAL_CURL}" "$@"
STUB
chmod 755 "${HARNESS_STUB_DIR}/systemctl" "${HARNESS_STUB_DIR}/ollama" "${HARNESS_STUB_DIR}/curl"

export PATH="${HARNESS_STUB_DIR}:${PATH}"

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------
# Register a command (function name plus args) to run at exit, before the
# temp root is removed.
harness_on_exit() {
    HARNESS_EXIT_HOOKS+=("$*")
}

_harness_exit() {
    local rc=$? hook pid failed=0
    # Subshells and command substitutions must never tear the root down.
    [[ "${BASHPID}" == "${HARNESS_MAIN_BASHPID}" ]] || return "${rc}"
    trap - EXIT
    for hook in "${HARNESS_EXIT_HOOKS[@]}"; do
        eval "${hook}" || true
    done
    for pid in "${HARNESS_BG_PIDS[@]}"; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done
    [[ -s "${HARNESS_FAILURES}" ]] && failed=1
    if [[ "${HARNESS_KEEP:-0}" == "1" ]]; then
        echo "[harness] kept ${HARNESS_ROOT}" >&2
    else
        rm -rf "${HARNESS_ROOT}"
    fi
    if ((rc == 0 && failed)); then
        echo "[harness] assertions failed; exiting 1" >&2
        rc=1
    fi
    exit "${rc}"
}
trap _harness_exit EXIT

# Start a background helper that must be killed at exit. Do not call it in a
# command substitution: the child has to belong to the main shell.
harness_spawn() { # <command...> ; sets HARNESS_LAST_PID
    "$@" &
    HARNESS_LAST_PID=$!
    HARNESS_BG_PIDS+=("${HARNESS_LAST_PID}")
}

# Start tests/lib/fake_ollama.py on a free loopback port. Extra args go to the
# fixture (see its --help). Sets FAKE_OLLAMA_URL, FAKE_OLLAMA_PORT,
# FAKE_OLLAMA_LOG (one "METHOD /path" line per request).
harness_fake_ollama() {
    local portfile="${HARNESS_ROOT}/fake-ollama.$$.${RANDOM}.port" tries=0
    FAKE_OLLAMA_LOG="${HARNESS_ROOT}/fake-ollama.${RANDOM}.log"
    : >"${FAKE_OLLAMA_LOG}"
    harness_spawn python3 "${HARNESS_DIR}/fake_ollama.py" --port 0 \
        --port-file "${portfile}" --log "${FAKE_OLLAMA_LOG}" "$@"
    while [[ ! -s "${portfile}" ]]; do
        if ((tries++ > 100)) || ! kill -0 "${HARNESS_LAST_PID}" 2>/dev/null; then
            bad "fake Ollama fixture did not start"
            return 1
        fi
        sleep 0.05
    done
    FAKE_OLLAMA_PORT="$(<"${portfile}")"
    # shellcheck disable=SC2034  # consumed by the tests that source this file
    FAKE_OLLAMA_URL="http://127.0.0.1:${FAKE_OLLAMA_PORT}"
}

# Restore the real environment for an opt-in live tier.
harness_use_real_env() {
    local var
    for var in "${HARNESS_MANAGED_VARS[@]}"; do
        unset "${var}"
    done
    eval "$(sed -n 's/^declare -x /export /p' <<<"${HARNESS_REAL_ENV}")"
    export PATH="${HARNESS_REAL_PATH}"
}

# Lines of the stub log for one command name ("" when it was never called).
harness_stub_calls() { # <name>
    grep -E "^$1( |$)" "${HARNESS_STUB_LOG}" || true
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
pass=0
fail=0
skipped=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    _H_GREEN=$'\033[32m' _H_RED=$'\033[31m' _H_YELLOW=$'\033[33m' _H_RESET=$'\033[0m'
else
    _H_GREEN="" _H_RED="" _H_YELLOW="" _H_RESET=""
fi

ok() {
    printf '  %sPASS%s %s\n' "${_H_GREEN}" "${_H_RESET}" "$1"
    pass=$((pass + 1))
}
bad() {
    printf '  %sFAIL%s %s\n' "${_H_RED}" "${_H_RESET}" "$1"
    printf '%s\n' "$1" >>"${HARNESS_FAILURES}"
    fail=$((fail + 1))
}
skip() {
    printf '  %sSKIP%s %s\n' "${_H_YELLOW}" "${_H_RESET}" "$1"
    skipped=$((skipped + 1))
}

check() { # <label> <expected> <actual>
    if [[ "$3" == "$2" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}
check_match() { # <label> <regex> <actual>
    if [[ "$3" =~ $2 ]]; then ok "$1"; else bad "$1: '$3' did not match '$2'"; fi
}
check_contains() { # <label> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1: output did not contain '$2'"; fi
}
check_not_contains() { # <label> <needle> <haystack>
    if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1: '$3' unexpectedly contains '$2'"; fi
}
assert_eq() { check "$@"; }
assert_match() { check_match "$@"; }
assert_contains() { check_contains "$@"; }
assert_not_contains() { check_not_contains "$@"; }
assert_ok() { # <label> <command...>
    local label="$1"
    shift
    if "$@"; then ok "${label}"; else bad "${label}"; fi
}
assert_fails() { # <label> <command...>
    local label="$1"
    shift
    if "$@"; then bad "${label}: command unexpectedly succeeded"; else ok "${label}"; fi
}
# No stub-recorded call to <name> (e.g. systemctl) happened since the last reset.
assert_no_stub_calls() { # <label> <name>
    local calls
    calls="$(harness_stub_calls "$2")"
    if [[ -z "${calls}" ]]; then ok "$1"; else bad "$1: unexpected calls: ${calls//$'\n'/; }"; fi
}
harness_reset_stub_log() {
    : >"${HARNESS_STUB_LOG}"
}

# Captured argv/env helpers for the fake-CLI pattern used by the launch tests:
# a capture file holds "ARGV", one arg per line, "ENV", then KEY=value lines.
has_flag() { awk -v f="$2" '$0==f{found=1} END{exit !found}' "$1"; }
flag_val() { awk -v f="$2" '$0==f{getline; print; exit}' "$1"; }
env_val() { sed -n "s/^$2=//p" "$1" | head -n1; }

# Print "<title>: N passed, M failed[, K skipped]" and return non-zero on any
# failure, including ones recorded from subshells.
harness_summary() { # [title]
    local total_fail
    total_fail="$(grep -c '' "${HARNESS_FAILURES}" || true)"
    if ((skipped > 0)); then
        echo "${1:-summary}: ${pass} passed, ${total_fail} failed, ${skipped} skipped"
    else
        echo "${1:-summary}: ${pass} passed, ${total_fail} failed"
    fi
    ((total_fail == 0))
}
