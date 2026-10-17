#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- qwen_update_test.sh ----------
# 'kimo update qwen' must update the copy PATH actually runs: Qwen Code's
# standalone install (a sh wrapper into a dir with manifest.json) goes through
# 'qwen update' and never npm; an npm install still uses npm.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
STUBS="$(mktemp -d)"
CALLS="${STUBS}/calls.log"
NPM_PREFIX="${HOME}/npm-global"
QDIR="${HOME}/.local/lib/qwen-code"
export CALLS NPM_PREFIX

cat > "${STUBS}/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "${CALLS}"
case "$1 $2" in
    "view @qwen-code/qwen-code") echo "0.25.2" ;;
    "prefix -g") echo "${NPM_PREFIX}" ;;
    "install -g")
        pkg="${NPM_PREFIX}/lib/node_modules/@qwen-code/qwen-code"
        mkdir -p "${pkg}" "${NPM_PREFIX}/bin"
        printf '#!/usr/bin/env bash\necho 0.25.2\n' > "${pkg}/cli-entry.js"
        chmod +x "${pkg}/cli-entry.js"
        ln -sfn "${pkg}/cli-entry.js" "${NPM_PREFIX}/bin/qwen" ;;
    *) exit 1 ;;
esac
SH
chmod +x "${STUBS}/npm"
BASE_PATH="${STUBS}:${HOME}/.local/bin:${NPM_PREFIX}/bin:${HARNESS_STUB_DIR}:/usr/bin:/bin"

reset_installs() {
    rm -rf "${QDIR}" "${HOME}/.local/bin" "${NPM_PREFIX}"
    : > "${CALLS}"
}
# Standalone layout as the Qwen installer writes it. bin/qwen reports the
# manifest version; 'qwen update' bumps it, like the real self-updater.
setup_standalone() { # [manifest name]
    mkdir -p "${QDIR}/bin" "${HOME}/.local/bin"
    printf '{"name": "%s", "version": "0.25.1", "target": "linux-arm64"}\n' "${1:-@qwen-code/qwen-code}" > "${QDIR}/manifest.json"
    cat > "${QDIR}/bin/qwen" <<SH
#!/usr/bin/env bash
m="${QDIR}/manifest.json"
case "\$1" in
    --version) sed -nE 's/.*"version": "([^"]+)".*/\1/p' "\$m" ;;
    update)
        echo "qwen \$*" >> "\${CALLS}"
        [[ -n "\${QWEN_UPDATE_FAIL:-}" ]] && { echo "update failed" >&2; exit 1; }
        sed -i 's/0\.25\.1/0.25.2/' "\$m" ;;
esac
SH
    chmod +x "${QDIR}/bin/qwen"
    printf "#!/usr/bin/env sh\nexec '%s' \"\$@\"\n" "${QDIR}/bin/qwen" > "${HOME}/.local/bin/qwen"
    chmod +x "${HOME}/.local/bin/qwen"
}
setup_npm_old() {
    local pkg="${NPM_PREFIX}/lib/node_modules/@qwen-code/qwen-code"
    mkdir -p "${pkg}" "${NPM_PREFIX}/bin"
    printf '#!/usr/bin/env bash\necho 0.25.1\n' > "${pkg}/cli-entry.js"
    chmod +x "${pkg}/cli-entry.js"
    ln -sfn "${pkg}/cli-entry.js" "${NPM_PREFIX}/bin/qwen"
}
run_update() { # sets rc, out
    rc=0
    out=$(PATH="${BASE_PATH}" "${KIMO}" update qwen 2>&1 </dev/null) || rc=$?
}

# 1) Standalone install: native updater through the sh wrapper, no npm.
reset_installs; setup_standalone
run_update
check "standalone: update succeeds" "0" "${rc}"
check_contains "standalone: uses 'qwen update'" "qwen update" "$(cat "${CALLS}")"
check_not_contains "standalone: never npm-installs" "npm install" "$(cat "${CALLS}")"
check_contains "standalone: upgrade verified" "verified upgrade 0.25.1 -> 0.25.2" "${out}"

# 2) Standalone updater failure: reported, and no npm fallback.
reset_installs; setup_standalone
QWEN_UPDATE_FAIL=1 run_update
check "standalone failure: update fails" "1" "${rc}"
check_contains "standalone failure: explains no npm fallback" "not falling back to npm" "${out}"
check_not_contains "standalone failure: never npm-installs" "npm install" "$(cat "${CALLS}")"

# 3) npm install: npm is used and the new version is verified.
reset_installs; setup_npm_old
run_update
check "npm: update succeeds" "0" "${rc}"
check_contains "npm: installs the scoped package" "npm install -g @qwen-code/qwen-code" "$(cat "${CALLS}")"
check_not_contains "npm: no standalone updater" "qwen update" "$(cat "${CALLS}")"
check_contains "npm: upgrade verified" "verified upgrade 0.25.1 -> 0.25.2" "${out}"

# 4) A manifest.json that is not Qwen's does not count as standalone.
reset_installs; setup_standalone "some-other-tool"
run_update
check_not_contains "foreign manifest: not treated as standalone" "qwen update" "$(cat "${CALLS}")"
check_contains "foreign manifest: falls through to npm" "npm install -g @qwen-code/qwen-code" "$(cat "${CALLS}")"

rm -rf "${STUBS}"
harness_summary "qwen update"
