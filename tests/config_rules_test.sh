#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- config_rules_test.sh ----------
# The loader, `config set` and `config validate` share one parser and one set
# of per-key rules; precedence is env > file > default; JSON is always valid.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
WORK="$(mktemp -d)"
CFG="${WORK}/config"
kimo_cfg() { KIMO_CONFIG_FILE="${CFG}" "${KIMO}" "$@"; }
list_val() { kimo_cfg config list 2>/dev/null | awk -v k="$1" '$1 == k {print $2}'; }
list_src() { kimo_cfg config list 2>/dev/null | awk -v k="$1" '$1 == k {print $NF}'; }

# 1) config set cannot inject extra keys or write a malformed key.
: > "${CFG}"
rc=0
out=$(kimo_cfg config set default_model $'llama3\nremote_url=http://evil.invalid:11434' 2>&1) || rc=$?
check "a newline in a value is rejected" "1" "${rc}"
check_contains "the rejection names the control character" "control character" "${out}"
check "nothing was written" "" "$(cat "${CFG}")"
rc=0
kimo_cfg config set $'a\nb' 1 >/dev/null 2>&1 || rc=$?
check "a newline in a key is rejected" "1" "${rc}"

# 2) Per-key rules apply to set (previously unchecked keys included).
for bad in "remote_url|not a url" "remote_url|ftp://x" "web_engine|yahoo" "web_max_results|5;alert(1)" \
           "default_host|two words" "remote_host|http://h:1" "default_model|bad model"; do
    rc=0
    kimo_cfg config set "${bad%%|*}" "${bad#*|}" >/dev/null 2>&1 || rc=$?
    check "config set rejects ${bad%%|*}='${bad#*|}'" "1" "${rc}"
done
for good in "remote_url|http://192.168.1.5:11434" "remote_url|https://[::1]:11434/ollama" "local_url|127.0.0.1:11434" \
            "default_host|remote" "remote_host|desktop.lan" "web_engine|google" "web_max_results|25" "no_color|no"; do
    rc=0
    kimo_cfg config set "${good%%|*}" "${good#*|}" >/dev/null 2>&1 || rc=$?
    check "config set accepts ${good%%|*}='${good#*|}'" "0" "${rc}"
done
rc=0
out=$(kimo_cfg config set remote_host 10.0.0.2 2>&1) || rc=$?
check_not_contains "remote_host is a standard key" "not a standard" "${out}"

# 3) validate uses the loader's parser: quotes and ';' comments are fine,
#    malformed lines and bad values are reported, JSON stays valid.
printf '%s\n' '; a comment' 'web_engine = "bing"' "remote_host='desktop'" > "${CFG}"
rc=0
kimo_cfg config validate >/dev/null 2>&1 || rc=$?
check "quoted values and ; comments validate" "0" "${rc}"
check "a quoted value loads without its quotes" "bing" "$(list_val web_engine)"
printf '%s\n' 'remote_url=ftp://x' 'garbage line' 'web_max_results=5;x' 'web_engine=google' > "${CFG}"
rc=0
json=$(kimo_cfg config validate --json) || rc=$?
check "invalid entries fail validation" "1" "${rc}"
check "three problems are listed" "3" "$(jq '.invalid_values | length' <<<"${json}")"
check_contains "malformed lines are reported by number" "line 2" "${json}"
check "the valid entry is counted" "1" "$(jq '.verified_entries' <<<"${json}")"
rc=0
json=$(KIMO_CONFIG_FILE="${WORK}/no\"pe" "${KIMO}" config validate --json) || rc=$?
check "a missing file fails" "1" "${rc}"
check "a quote in the path still yields valid JSON" "Config file not found" "$(jq -r .error <<<"${json}")"

# 4) The loader skips invalid values and warns, outside of `config`.
check_not_contains "an invalid file URL is not applied" "ftp://x" "$(OLLAMA_REMOTE_URL='' list_val remote_url)"
check "an invalid max-results value falls back to 10" "10" "$(list_val web_max_results)"
out=$(KIMO_CONFIG_FILE="${CFG}" "${KIMO}" web --help 2>&1 >/dev/null || true)
check_contains "other commands warn about ignored values" "Ignoring invalid setting remote_url" "${out}"
out=$(kimo_cfg config list 2>&1 >/dev/null || true)
check_not_contains "config itself does not repeat the warning" "Ignoring" "${out}"

# 5) Precedence: env beats the file for every key, and env values that reach
#    printed JS/URLs are checked too.
printf '%s\n' 'web_engine=google' 'web_max_results=7' > "${CFG}"
check "env KIMO_WEB_ENGINE beats the file" "bing" "$(KIMO_WEB_ENGINE=bing list_val web_engine)"
check "the source shows the env var" "env:KIMO_WEB_ENGINE" "$(KIMO_WEB_ENGINE=bing list_src web_engine)"
check "env KIMO_WEB_MAX_RESULTS beats the file" "3" "$(KIMO_WEB_MAX_RESULTS=3 list_val web_max_results)"
check "a hostile env max-results is replaced" "10" "$(KIMO_WEB_MAX_RESULTS='3);x(' list_val web_max_results)"

# 6) Color: config no_color survives option parsing; any non-empty NO_COLOR
#    disables color (checked on a pseudo-terminal, where color is otherwise on).
tty_has_ansi() { # <config file> [env assignments...]
    local cfg="$1"
    shift
    env KIMO_CONFIG_FILE="${cfg}" "$@" python3 -I - "${KIMO}" <<'PY'
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "config", "validate"])
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
print("yes" if b"\x1b[" in out else "no")
PY
}
printf '%s\n' 'default_host=remote' > "${CFG}"
check "control: color on a terminal" "yes" "$(tty_has_ansi "${CFG}")"
check "NO_COLOR=true disables color" "no" "$(tty_has_ansi "${CFG}" NO_COLOR=true)"
printf '%s\n' 'default_host=remote' 'no_color=yes' > "${CFG}"
check "config no_color=yes disables color" "no" "$(tty_has_ansi "${CFG}")"

rm -rf "${WORK}"
harness_summary "config_rules_test.sh"
