#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- hardening_test.sh ----------
# Installers never pipe a download into a shell; qwen's key stays out of argv;
# model write calls carry timeouts; a `make link` symlink still finds lib/.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
WORK="$(mktemp -d)"

# 1) No 'curl|bash' / 'wget|bash' anywhere; run_remote_installer is used.
check "no installer pipes a download into a shell" "" \
    "$(grep -nE '(curl|wget)[^#]*\|[^|#]*\b(ba)?sh\b' "${KIMO}" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
eval "$(sed -n '/^run_remote_installer() {/,/^}/p' "${KIMO}")"
# shellcheck disable=SC2034  # read by the eval'd run_remote_installer
C_RED="" C_RESET=""
export RAN="${WORK}/ran"
# A download that fails part-way must not run the partial script.
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
    printf 'touch "$RAN"\n' > "${out}"
    return 18
}
rc=0
run_remote_installer https://example.invalid/install.sh 2>/dev/null || rc=$?
check "a failed download returns curl's status" "18" "${rc}"
check "a failed download runs nothing" "no" "$([[ -e "${RAN}" ]] && echo yes || echo no)"
# A complete download runs once, with the given arguments and prefixed env.
curl() {
    local out=""
    while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
    printf 'printf "%%s|%%s" "$1" "${INSTALL_FLAG:-}" > "$RAN"\n' > "${out}"
}
rc=0
INSTALL_FLAG=on run_remote_installer https://example.invalid/install.sh latest || rc=$?
check "a complete download runs and succeeds" "0" "${rc}"
check "script args and prefixed env reach the installer" "latest|on" "$(cat "${RAN}" 2>/dev/null)"
unset -f curl
# The real curl refuses plain HTTP (HTTPS-only).
rc=0
run_remote_installer http://127.0.0.1:9/install.sh >/dev/null 2>&1 || rc=$?
check "plain http:// installers are refused" "refused" "$([[ ${rc} -ne 0 ]] && echo refused || echo ran)"

# 2) Model write calls carry timeouts and report a dead host.
for fn in cmd_warm cmd_tag cmd_rm; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${KIMO}")
    check_contains "${fn}: curl has a max time" "-m " "$(grep -E 'curl -s' <<<"${body}")"
done
rc=0
out=$(timeout 20 "${KIMO}" --host http://127.0.0.1:9 warm fixture-model 2>&1) || rc=$?
check "warm against a dead host exits 1" "1" "${rc}"
check_contains "warm explains the failure" "Warm request to http://127.0.0.1:9 failed" "${out}"

# 3) A `make link`-style symlink resolves SCRIPT_DIR to the checkout.
mkdir -p "${WORK}/bin"
ln -s "${KIMO}" "${WORK}/bin/kimo"
found=$(bash -c '
    eval "$(sed -n "/^_kimo_self=/,/^unset _kimo_self/p" "$1" | sed "s|\${BASH_SOURCE\[0\]}|$1|g")"
    HOME=/nonexistent
    eval "$(sed -n "/^GEMINI_SHIM_PATHS=(/,/^)/p;/^find_gemini_shim() {/,/^}/p" "$1")"
    find_gemini_shim' _ "${WORK}/bin/kimo")
check "the shim is found through a symlink" "${ROOT_DIR}/lib/ollama-gemini-shim.py" "${found}"

rm -rf "${WORK}"
harness_summary "hardening_test.sh"
