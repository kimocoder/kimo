#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- codex_update_test.sh ----------
# 'kimo update codex' must update the copy PATH actually runs: a standalone
# install (OpenAI's installer, ~/.codex/packages/standalone) goes through
# 'codex update' and never npm; an npm install must report npm failures and
# warn when another codex shadows the one npm just installed. PATH is the
# stubs plus system dirs only, so the operator's real CLIs never leak in.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
STUBS="$(mktemp -d)"
CALLS="${STUBS}/calls.log"
NPM_PREFIX="${HOME}/npm-global"
STANDALONE="${HOME}/.codex/packages/standalone"
export CALLS NPM_PREFIX STANDALONE

# A codex binary that reports a fixed version and implements the standalone
# 'update' verb by repointing $STANDALONE/current, like the real updater.
fake_codex() { # <path> <version>
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<SH
#!/usr/bin/env bash
case "\$1" in
    --version) echo "codex-cli $2" ;;
    update)
        echo "codex \$*" >> "\${CALLS}"
        [[ -n "\${CODEX_UPDATE_FAIL:-}" ]] && { echo "update: network error" >&2; exit 1; }
        ln -sfn "\${STANDALONE}/releases/0.163.0-test" "\${STANDALONE}/current" ;;
esac
SH
    chmod +x "$1"
}

cat > "${STUBS}/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "${CALLS}"
case "$1 $2" in
    "view @openai/codex") echo "0.163.0" ;;
    "prefix -g") echo "${NPM_PREFIX}" ;;
    "install -g")
        [[ -n "${NPM_FAIL:-}" ]] && { echo "npm ERR! network" >&2; exit 1; }
        mkdir -p "${NPM_PREFIX}/bin"
        printf '#!/usr/bin/env bash\necho "codex-cli 0.163.0"\n' > "${NPM_PREFIX}/bin/codex"
        chmod +x "${NPM_PREFIX}/bin/codex" ;;
    *) exit 1 ;;
esac
SH
chmod +x "${STUBS}/npm"
BASE_PATH="${STUBS}:${HOME}/.local/bin:${NPM_PREFIX}/bin:${HARNESS_STUB_DIR}:/usr/bin:/bin"

reset_installs() {
    rm -rf "${HOME}/.codex" "${HOME}/.local/bin" "${NPM_PREFIX}" "${HOME}/shadow"
    : > "${CALLS}"
}
setup_standalone() {
    fake_codex "${STANDALONE}/releases/0.162.1-test/bin/codex" 0.162.1
    fake_codex "${STANDALONE}/releases/0.163.0-test/bin/codex" 0.163.0
    ln -sfn "${STANDALONE}/releases/0.162.1-test" "${STANDALONE}/current"
    mkdir -p "${HOME}/.local/bin"
    ln -sfn "${STANDALONE}/current/bin/codex" "${HOME}/.local/bin/codex"
}
run_update() { # [extra PATH prefix] ; sets rc, out
    rc=0
    out=$(PATH="${1:+$1:}${BASE_PATH}" "${KIMO}" update codex 2>&1 </dev/null) || rc=$?
}

# 1) Standalone install: native updater, no npm install, verified upgrade.
reset_installs; setup_standalone
run_update
check "standalone: update succeeds" "0" "${rc}"
check_contains "standalone: uses 'codex update'" "codex update" "$(cat "${CALLS}")"
check_not_contains "standalone: never npm-installs" "npm install" "$(cat "${CALLS}")"
check_contains "standalone: upgrade verified" "verified upgrade 0.162.1 -> 0.163.0" "${out}"
check "standalone: no npm copy created" "no" "$([[ -e "${NPM_PREFIX}/bin/codex" ]] && echo yes || echo no)"

# 2) Standalone updater failure: reported, and no npm fallback.
reset_installs; setup_standalone
CODEX_UPDATE_FAIL=1 run_update
check "standalone failure: update fails" "1" "${rc}"
check_contains "standalone failure: explains no npm fallback" "not falling back to npm" "${out}"
check_not_contains "standalone failure: never npm-installs" "npm install" "$(cat "${CALLS}")"

# 3) npm install: npm is used and the new version is verified.
reset_installs
fake_codex "${NPM_PREFIX}/bin/codex" 0.162.1
run_update
check "npm: update succeeds" "0" "${rc}"
check_contains "npm: installs the scoped package" "npm install -g @openai/codex" "$(cat "${CALLS}")"
check_not_contains "npm: no standalone updater" "codex update" "$(cat "${CALLS}")"
check_contains "npm: upgrade verified" "verified upgrade 0.162.1 -> 0.163.0" "${out}"
check_not_contains "npm: no shadow warning" "PATH resolves" "${out}"

# 4) npm failure: no success message, non-zero exit.
reset_installs
fake_codex "${NPM_PREFIX}/bin/codex" 0.162.1
NPM_FAIL=1 run_update
check "npm failure: update fails" "1" "${rc}"
check_contains "npm failure: reported" "Codex installation failed" "${out}"
check_not_contains "npm failure: no success claim" "Successfully installed" "${out}"

# 5) npm copy shadowed by another (non-standalone) codex earlier on PATH.
reset_installs
fake_codex "${NPM_PREFIX}/bin/codex" 0.162.1
fake_codex "${HOME}/shadow/codex" 0.162.1
run_update "${HOME}/shadow"
check "shadowed: update not verified" "1" "${rc}"
check_contains "shadowed: warns which codex PATH runs" "PATH resolves 'codex' to ${HOME}/shadow/codex" "${out}"

rm -rf "${STUBS}"
harness_summary "codex update"
