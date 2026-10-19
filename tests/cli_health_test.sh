#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- cli_health_test.sh ----------
# An installer that exits 0 is not a working CLI. npm can skip a package's
# install script (allowScripts), leaving a bin that only prints an error:
# kimo must name skipped scripts, refuse to call such an update verified, and
# print the --allow-scripts command for the owning package.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
STUBS="$(mktemp -d)"
CALLS="${STUBS}/calls.log"
NPM_PREFIX="${HOME}/npm-global"
OC_PKG="${NPM_PREFIX}/lib/node_modules/@opencode/cli"
export CALLS NPM_PREFIX OC_PKG

# npm: 'install -g' prints npm's blocked-install-scripts warning when
# NPM_BLOCKED is set; qwen's package is the target for that case.
cat > "${STUBS}/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >> "${CALLS}"
case "$1 $2" in
    "view @opencode/cli") echo "2.0.32" ;;
    "view @qwen-code/qwen-code") echo "0.25.2" ;;
    "prefix -g") echo "${NPM_PREFIX}" ;;
    "install -g")
        pkg="${NPM_PREFIX}/lib/node_modules/@qwen-code/qwen-code"
        mkdir -p "${pkg}" "${NPM_PREFIX}/bin"
        printf '#!/usr/bin/env bash\necho 0.25.2\n' > "${pkg}/cli-entry.js"
        chmod +x "${pkg}/cli-entry.js"
        ln -sfn "${pkg}/cli-entry.js" "${NPM_PREFIX}/bin/qwen"
        echo "changed 13 packages in 7s"
        if [[ -n "${NPM_BLOCKED:-}" ]]; then
            echo "npm warn install-scripts 1 package had install scripts blocked because they are not covered by allowScripts:" >&2
            echo "npm warn install-scripts   @qwen-code/audio-capture@0.25.2 (install: node install.js)" >&2
            echo "npm warn install-scripts" >&2
        fi ;;
    *) exit 1 ;;
esac
SH
chmod +x "${STUBS}/npm"
BASE_PATH="${STUBS}:${NPM_PREFIX}/bin:${HARNESS_STUB_DIR}:/usr/bin:/bin"

# opencode from npm. 'upgrade' leaves the bin as the postinstall stub, as npm
# does when it skips @opencode/cli's postinstall.
oc_working() { # <version>
    mkdir -p "${OC_PKG}/bin" "${NPM_PREFIX}/bin"
    cat > "${OC_PKG}/bin/opencode.exe" <<SH
#!/usr/bin/env bash
case "\$1" in
    --version) echo "opencode v$1" ;;
    upgrade)
        echo "opencode \$*" >> "\${CALLS}"
        printf '#!/usr/bin/env bash\necho "Error: @opencode/cli'"'"'s postinstall script was not run." >&2\nexit 1\n' > "\${OC_PKG}/bin/opencode.exe" ;;
esac
SH
    chmod +x "${OC_PKG}/bin/opencode.exe"
    ln -sfn "${OC_PKG}/bin/opencode.exe" "${NPM_PREFIX}/bin/opencode"
}
reset_installs() { rm -rf "${NPM_PREFIX}"; : > "${CALLS}"; }
run_kimo() { # <args...> ; sets rc, out
    rc=0
    out=$(PATH="${BASE_PATH}" "${KIMO}" "$@" 2>&1 </dev/null) || rc=$?
}

# 1) An upgrade that leaves a non-running bin is a failure, with the fix.
reset_installs; oc_working 2.0.28
run_kimo update opencode
check "broken upgrade: update fails" "1" "${rc}"
check_contains "broken upgrade: upgrade ran" "opencode upgrade" "$(cat "${CALLS}")"
check_contains "broken upgrade: says the CLI does not run" "opencode is installed at ${NPM_PREFIX}/bin/opencode but does not run" "${out}"
check_contains "broken upgrade: shows the CLI's error" "postinstall script was not run" "${out}"
check_contains "broken upgrade: names the fix for the owning package" \
    "npm install -g --allow-scripts=@opencode/cli @opencode/cli" "${out}"
check_not_contains "broken upgrade: never called verified" "verified upgrade" "${out}"

# 2) 'install' of an already-installed but broken CLI reports it too.
run_kimo install opencode
check "broken existing install: install fails" "1" "${rc}"
check_contains "broken existing install: reported" "does not run" "${out}"

# 3) A healthy CLI passes the check.
reset_installs; oc_working 2.0.32
run_kimo install opencode
check "healthy install: succeeds" "0" "${rc}"
check_not_contains "healthy install: no health warning" "does not run" "${out}"

# 4) npm's blocked-install-scripts warning is surfaced with a command, but a
#    CLI that still runs is not failed for it.
# --update keeps this portable: on boxes with a system-wide qwen (e.g.
# /usr/bin/qwen) a plain 'install qwen' takes the already-installed early
# return and never reaches the npm path the blocked-scripts warning lives on.
reset_installs
NPM_BLOCKED=1 run_kimo install qwen --update
check "blocked scripts: install still succeeds" "0" "${rc}"
check_contains "blocked scripts: names the package" "npm skipped install scripts for: @qwen-code/audio-capture" "${out}"
check_contains "blocked scripts: prints allow command" \
    "npm install -g --allow-scripts=@qwen-code/audio-capture @qwen-code/qwen-code" "${out}"
reset_installs
run_kimo install qwen --update
check_not_contains "no blocked scripts: no warning" "npm skipped install scripts" "${out}"

rm -rf "${STUBS}"
harness_summary "cli health"
