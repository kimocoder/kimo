#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- update_lookup_test.sh ----------
# 'kimo update' latest-version lookups for grok and kimi: every output shape
# the upstream tools emit must resolve to a plain version, and anything else
# (errors, HTML, prose) must resolve to nothing so the row reads "unknown"
# instead of comparing garbage.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
STUBS="$(mktemp -d)"

for fn in _bounded_update_lookup _plain_version _compare_cli_versions _grok_latest_version _kimi_latest_version; do
    eval "$(sed -n "/^${fn}() {/,/^}/p" "${KIMO}")"
done

# grok stub: GROK_JSON answers 'update --check --json', GROK_TEXT the plain form.
cat > "${STUBS}/grok" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${STUB_CALLS}"
if [[ " $* " == *" --json "* ]]; then
    [[ -n "${GROK_JSON:-}" ]] || { echo "error: unknown flag --json" >&2; exit 2; }
    printf '%s\n' "${GROK_JSON}"
else
    printf '%s\n' "${GROK_TEXT:-}"
fi
SH
# npm stub: answers 'view @moonshot-ai/kimi-code version' when KIMI_NPM_VER is set.
cat > "${STUBS}/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "${STUB_CALLS}"
if [[ "$1 $2 $3" == "view @moonshot-ai/kimi-code version" && -n "${KIMI_NPM_VER:-}" ]]; then
    printf '%s\n' "${KIMI_NPM_VER}"
    exit 0
fi
exit 1
SH
# curl stub: prints CURL_BODY (or KIMI_REG_BODY for registry.npmjs.org), or fails when CURL_FAIL is set.
cat > "${STUBS}/curl" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${STUB_CALLS}"
[[ -n "${CURL_FAIL:-}" ]] && exit 28
if [[ "$*" == *"registry.npmjs.org/@moonshot-ai/kimi-code/latest"* ]]; then
    printf '%s' "${KIMI_REG_BODY:-}"
    exit 0
fi
printf '%s' "${CURL_BODY:-}"
SH
chmod +x "${STUBS}/grok" "${STUBS}/npm" "${STUBS}/curl"
export PATH="${STUBS}:${PATH}" STUB_CALLS="${STUBS}/calls.log"

grok_case() { # <label> <expected> <json> <text>
    check "grok: $1" "$2" "$(GROK_JSON="$3" GROK_TEXT="$4" _grok_latest_version)"
}
kimi_case() { # <label> <expected> <body> [fail] [npm_ver] [reg_body]
    check "kimi: $1" "$2" "$(CURL_BODY="$3" CURL_FAIL="${4:-}" KIMI_NPM_VER="${5:-}" KIMI_REG_BODY="${6:-}" _kimi_latest_version)"
}

# 1) grok: JSON is preferred, text forms are the fallback.
grok_case "JSON latestVersion" "1.0.62" \
    '{"currentVersion":"1.0.50","latestVersion":"1.0.62","updateAvailable":true,"error":null}' ""
grok_case "JSON alpha prerelease" "1.0.63-alpha.2" \
    '{"currentVersion":"1.0.50","latestVersion":"1.0.63-alpha.2","channel":"alpha"}' ""
grok_case "JSON wins over text" "1.0.62" \
    '{"latestVersion":"1.0.62"}' "A new version of Grok Build is available: 1.0.50 -> 9.9.9 [stable]"
grok_case "arrow text without --json" "1.0.62" \
    "" "A new version of Grok Build is available: 1.0.50 -> 1.0.62 [stable]"
grok_case "legacy 'latest:' text" "0.1.151" "" "current: 0.1.150, latest: 0.1.151"
grok_case "JSON lookup error" "" '{"currentVersion":"1.0.50","latestVersion":null,"error":"network"}' ""
grok_case "up-to-date prose has no version" "" "" "Grok Build is up to date."
grok_case "non-version value rejected" "" '{"latestVersion":"unknown"}' ""

# 2) kimi: whitespace and a leading v are tolerated; non-versions are not;
#    when npm (@moonshot-ai/kimi-code) is ahead of the CDN feed, the newer
#    release wins so an up-to-date install does not report 'ahead'.
kimi_case "plain body" "2.2.0" "2.2.0"
kimi_case "trailing CRLF" "2.2.0" $'2.2.0\r\n'
kimi_case "leading v" "2.2.0" "v2.2.0"
kimi_case "HTML error page rejected" "" "<html><body>502 Bad Gateway</body></html>"
kimi_case "empty body" "" ""
kimi_case "curl failure" "" "2.2.0" fail
kimi_case "npm ahead of lagging CDN pointer" "2.6.1" "2.5.3" "" "2.6.1"
kimi_case "CDN ahead of npm" "2.6.2" "2.6.2" "" "2.6.1"
kimi_case "npm fallback when CDN fails" "2.6.1" "" fail "2.6.1"
kimi_case "registry JSON fallback when npm view fails" "2.6.1" "2.5.3" "" "" '{"name":"@moonshot-ai/kimi-code","version":"2.6.1"}'
: > "${STUB_CALLS}"
_kimi_latest_version >/dev/null
calls=$(cat "${STUB_CALLS}")
check_contains "kimi: uses the installer's feed" "https://code.kimi.com/kimi-code/latest" "${calls}"
check_contains "kimi: checks @moonshot-ai/kimi-code on npm" "npm view @moonshot-ai/kimi-code version" "${calls}"
check_contains "kimi: retries once" "--retry 1" "${calls}"
check_not_contains "kimi: no 2s connect timeout on CDN feed" "--connect-timeout 2 https://code.kimi.com" "${calls}"

rm -rf "${STUBS}"
harness_summary "update lookups"
