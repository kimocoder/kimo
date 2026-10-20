#!/usr/bin/env bash
# Headless smoke tests for kimo's GitHub CLI ('gh') integration.
#
# Asserts the contract for 'gh' in kimo across launch, install, update, doctor, and completions:
#   * Launch contract: 'kimo launch gh' execs 'gh copilot -- <args>' with GitHub
#     Copilot CLI's BYOK env pointed at <host>/v1 (COPILOT_PROVIDER_BASE_URL,
#     COPILOT_MODEL, COPILOT_PROVIDER_TYPE=openai), --ctx as
#     COPILOT_PROVIDER_MAX_PROMPT_TOKENS, COPILOT_OFFLINE defaulting to true,
#     provider keys scrubbed for non-local hosts, --dry-run, and hosted
#     --provider rejection. 'kimo run gh' still rejects gh as a model name.
#   * Install status contract:
#       - 'kimo install gh' reports existing binary when already installed.
#       - 'kimo install --force gh' refuses to replace/shadow an external system binary.
#       - named 'kimo update gh' updates an owned standalone gh in place (no flag needed).
#   * Update flag contract:
#       - rejects combining --check and --apply
#       - restricts --allow-system-path strictly to named 'update gh' (not batch 'update all')
#       - validates update --help documentation and eligible check behavior
#   * Inventory & Doctor contract:
#       - 'kimo install list' includes 'gh' row with its default launch model
#       - 'kimo doctor' detects 'gh' and formats its version and binary location
#   * Shell completion contract: bash & zsh completions expose 'gh' across launch, install and update.
#
# Optional live layer (--live): if a real 'gh' binary is installed on the host, runs
# a real version verification check, plus a 'gh copilot' turn against a
# reachable Ollama host when the Copilot CLI is available.
#
# Usage: tests/gh-smoke.sh [--live]

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_GH="$(mktemp -d)"

echo "=== Kimo GitHub CLI ('gh') Smoke Tests ==="

# 1. Launch contract: 'launch gh' runs GitHub Copilot CLI in BYOK mode
echo "[1] Launch contract (gh copilot routed to Ollama)"
LAUNCH_BIN="${TMPDIR_GH}/launch_bin"
LAUNCH_HOME="${TMPDIR_GH}/launch_home"
mkdir -p "${LAUNCH_BIN}" "${LAUNCH_HOME}"
CAPTURE="${TMPDIR_GH}/launch_call.txt"
export GH_SMOKE_OUT="${CAPTURE}"
cat > "${LAUNCH_BIN}/gh" <<'FAKE'
#!/usr/bin/env bash
out="${GH_SMOKE_OUT:?GH_SMOKE_OUT unset}"
{
    printf 'ARGV\n'
    printf '%s\n' "$@"
    printf 'ENV\n'
    for v in COPILOT_PROVIDER_BASE_URL COPILOT_PROVIDER_TYPE COPILOT_MODEL \
        COPILOT_PROVIDER_MAX_PROMPT_TOKENS COPILOT_OFFLINE COPILOT_PROVIDER_WIRE_MODEL \
        COPILOT_PROVIDER_API_KEY COPILOT_PROVIDER_BEARER_TOKEN; do
        printf '%s=%s\n' "${v}" "${!v-<unset>}"
    done
} > "${out}"
exit 0
FAKE
chmod +x "${LAUNCH_BIN}/gh"

# Unassigned port 9 so no real Ollama is contacted or unloaded. PATH puts the
# fake first; /usr/local/bin stays last because kimo prepends it only when
# absent, and a real gh there must not shadow the fake.
LOCAL_HOST="http://127.0.0.1:9"
REMOTE_HOST="http://192.168.1.131:9"
run_launch() { # [env assignments...] -- <kimo args...>
    local -a envs=()
    while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    rm -f "${CAPTURE}"
    env HOME="${LAUNCH_HOME}" PATH="${LAUNCH_BIN}:/usr/bin:/bin:/usr/local/bin" "${envs[@]}" \
        "${KIMO}" "$@" >/dev/null 2>&1 || true
}
argv_lines() { sed -n '/^ARGV$/,/^ENV$/p' "${CAPTURE}" | sed '1d;$d' | paste -sd' ' -; }

run_launch -- --host "${LOCAL_HOST}" launch gh --model kalidroid-27b:latest -p "hi there" --allow-tool 'shell(git)'
if [[ ! -f "${CAPTURE}" ]]; then
    bad "fake gh was never exec'd (no capture); cannot assert"
else
    check "argv is 'copilot --' plus passthrough" "copilot -- -p hi there --allow-tool shell(git)" "$(argv_lines)"
    check "COPILOT_PROVIDER_BASE_URL is host/v1" "${LOCAL_HOST}/v1" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_BASE_URL)"
    check "COPILOT_PROVIDER_TYPE is openai" "openai" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_TYPE)"
    check "COPILOT_MODEL is resolved model" "kalidroid-27b:latest" "$(env_val "${CAPTURE}" COPILOT_MODEL)"
    check "COPILOT_OFFLINE defaults to true" "true" "$(env_val "${CAPTURE}" COPILOT_OFFLINE)"
    check "no prompt cap without --ctx" "<unset>" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_MAX_PROMPT_TOKENS)"
fi

run_launch COPILOT_OFFLINE=false COPILOT_PROVIDER_WIRE_MODEL=stale -- --host "${LOCAL_HOST}" launch gh --model kalidroid-27b:latest --ctx 65536
check "--ctx becomes COPILOT_PROVIDER_MAX_PROMPT_TOKENS" "65536" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_MAX_PROMPT_TOKENS)"
check "user COPILOT_OFFLINE is honoured" "false" "$(env_val "${CAPTURE}" COPILOT_OFFLINE)"
check "stale COPILOT_PROVIDER_WIRE_MODEL is dropped" "<unset>" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_WIRE_MODEL)"
check "no args still separates gh flags with --" "copilot --" "$(argv_lines)"

run_launch COPILOT_PROVIDER_API_KEY=sk-local COPILOT_PROVIDER_BEARER_TOKEN=bt-local -- --host "${LOCAL_HOST}" launch gh --model kalidroid-27b:latest
check "provider key kept for plain local host" "sk-local" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_API_KEY)"
check "bearer token kept for plain local host" "bt-local" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_BEARER_TOKEN)"

run_launch OLLAMA_REMOTE_URL="${REMOTE_HOST}" COPILOT_PROVIDER_API_KEY=sk-secret COPILOT_PROVIDER_BEARER_TOKEN=bt-secret -- --remote launch gh --model kalidroid-27b:latest
check "COPILOT_PROVIDER_BASE_URL follows remote host" "${REMOTE_HOST}/v1" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_BASE_URL)"
check "provider key scrubbed for remote host" "<unset>" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_API_KEY)"
check "bearer token scrubbed for remote host" "<unset>" "$(env_val "${CAPTURE}" COPILOT_PROVIDER_BEARER_TOKEN)"

rm -f "${CAPTURE}"
DRY_OUT="$(env HOME="${LAUNCH_HOME}" PATH="${LAUNCH_BIN}:/usr/bin:/bin:/usr/local/bin" COPILOT_PROVIDER_API_KEY=sk-secret \
    "${KIMO}" --host "${LOCAL_HOST}" launch gh --model kalidroid-27b:latest --dry-run -- -p hi 2>&1 || true)"
check_contains "dry-run shows gh copilot argv" "argv   : gh copilot -- -p hi" "${DRY_OUT}"
check_contains "dry-run shows COPILOT_PROVIDER_BASE_URL" "COPILOT_PROVIDER_BASE_URL=${LOCAL_HOST}/v1" "${DRY_OUT}"
check_contains "dry-run masks provider key" "COPILOT_PROVIDER_API_KEY <kept: real value, plain local host>" "${DRY_OUT}"
check_not_contains "dry-run never prints the key" "sk-secret" "${DRY_OUT}"
[[ ! -f "${CAPTURE}" ]] && ok "dry-run does not exec gh" || bad "dry-run exec'd gh"

HOSTED_RC=0
HOSTED_OUT="$(ABLITERATION_API_KEY=ak_test "${KIMO}" launch gh --provider abliteration 2>&1)" || HOSTED_RC=$?
check "launch gh --provider abliteration exits 1" "1" "${HOSTED_RC}"
check_contains "hosted provider names gh as unsupported" "'gh' has no abliteration launch branch" "${HOSTED_OUT}"

# 2. Update flag contract
echo "[2] Update flag validation and error guards"
UPDATE_ALL_OUT="$("${KIMO}" update all --allow-system-path 2>&1 || true)"
UPDATE_ALL_RC=0
"${KIMO}" update all --allow-system-path >/dev/null 2>&1 || UPDATE_ALL_RC=$?

check "--allow-system-path on 'update all' exits with status 1" "1" "${UPDATE_ALL_RC}"
check_contains "--allow-system-path restricted to named update gh" "Error: --allow-system-path is only valid for the named 'update gh' target, not batch updates." "${UPDATE_ALL_OUT}"

UPDATE_CHECK_APPLY_OUT="$("${KIMO}" update gh --check --apply 2>&1 || true)"
UPDATE_CHECK_APPLY_RC=0
"${KIMO}" update gh --check --apply >/dev/null 2>&1 || UPDATE_CHECK_APPLY_RC=$?

check "update gh --check --apply exits with status 1" "1" "${UPDATE_CHECK_APPLY_RC}"
check_contains "cannot combine --check and --apply" "Error: --check and --apply cannot be combined." "${UPDATE_CHECK_APPLY_OUT}"

# Named 'update gh' is the opt-in for a standalone gh outside ~/.local/bin: it
# must get past the shadowing guard to the download (fake curl fails it there)
# and leave the existing binary untouched.
STANDALONE_DIR="${TMPDIR_GH}/standalone_bin"
STANDALONE_HOME="${TMPDIR_GH}/standalone_home"
mkdir -p "${STANDALONE_DIR}" "${STANDALONE_HOME}"
printf '#!/usr/bin/env bash\necho "gh version 2.99.0 (2026-01-01)"\n' > "${STANDALONE_DIR}/gh"
cat > "${STANDALONE_DIR}/curl" <<'FAKE'
#!/usr/bin/env bash
[[ " $* " == *" https://api.github.com/repos/cli/cli/releases/latest "* ]] || exit 22
echo '{"tag_name":"v2.100.0"}'
FAKE
chmod +x "${STANDALONE_DIR}/gh" "${STANDALONE_DIR}/curl"
STANDALONE_SUM="$(sha256sum "${STANDALONE_DIR}/gh")"
STANDALONE_RC=0
STANDALONE_OUT="$(HOME="${STANDALONE_HOME}" PATH="${STANDALONE_DIR}:/usr/bin:/bin" "${KIMO}" update gh 2>&1)" || STANDALONE_RC=$?
check_not_contains "named update gh does not refuse a standalone gh" "refusing to replace or shadow" "${STANDALONE_OUT}"
check_contains "named update gh reaches the release download" "Error: GitHub CLI download failed." "${STANDALONE_OUT}"
check "named update gh exits 1 when the download fails" "1" "${STANDALONE_RC}"
check "failed update leaves the standalone gh untouched" "${STANDALONE_SUM}" "$(sha256sum "${STANDALONE_DIR}/gh")"

# Successful in-place update from a fake release: the new binary is installed,
# and the backup and staging dir are removed once the new version verifies.
if [[ "$(uname -s)" == Linux ]]; then
    case "$(uname -m)" in
        x86_64|amd64) GH_ARCH=amd64 ;; aarch64|arm64) GH_ARCH=arm64 ;;
        i386|i686) GH_ARCH=386 ;; *) GH_ARCH=armv6 ;;
    esac
    RELEASE_DIR="${TMPDIR_GH}/release"
    UPGRADE_DIR="${TMPDIR_GH}/upgrade_bin"
    GH_ASSET="gh_2.100.0_linux_${GH_ARCH}.tar.gz"
    mkdir -p "${RELEASE_DIR}/gh_2.100.0_linux_${GH_ARCH}/bin" "${UPGRADE_DIR}"
    printf '#!/usr/bin/env bash\necho "gh version 2.100.0 (2026-02-01)"\n' > "${RELEASE_DIR}/gh_2.100.0_linux_${GH_ARCH}/bin/gh"
    chmod +x "${RELEASE_DIR}/gh_2.100.0_linux_${GH_ARCH}/bin/gh"
    tar -czf "${RELEASE_DIR}/${GH_ASSET}" -C "${RELEASE_DIR}" "gh_2.100.0_linux_${GH_ARCH}"
    (cd "${RELEASE_DIR}" && sha256sum "${GH_ASSET}" > checksums)
    cp "${STANDALONE_DIR}/gh" "${UPGRADE_DIR}/gh"
    cat > "${UPGRADE_DIR}/curl" <<'FAKE'
#!/usr/bin/env bash
url="" out=""
while [[ $# -gt 0 ]]; do
    case "$1" in -o) out="$2"; shift ;; https://*) url="$1" ;; esac
    shift
done
case "${url}" in
    https://api.github.com/repos/cli/cli/releases/latest) echo '{"tag_name":"v2.100.0"}' ;;
    */gh_2.100.0_checksums.txt) cp "${GH_FAKE_RELEASE}/checksums" "${out}" ;;
    */gh_2.100.0_linux_*.tar.gz) cp "${GH_FAKE_RELEASE}/${url##*/}" "${out}" ;;
    *) exit 22 ;;
esac
FAKE
    chmod +x "${UPGRADE_DIR}/curl"
    UPGRADE_RC=0
    UPGRADE_OUT="$(HOME="${STANDALONE_HOME}" PATH="${UPGRADE_DIR}:/usr/bin:/bin" GH_FAKE_RELEASE="${RELEASE_DIR}" \
        "${KIMO}" update gh 2>&1)" || UPGRADE_RC=$?
    check "named update gh succeeds from a valid release" "0" "${UPGRADE_RC}"
    check_contains "update reports the installed version" "Installed GitHub CLI 2.100.0 at ${UPGRADE_DIR}/gh." "${UPGRADE_OUT}"
    check "standalone gh now runs the new release" "gh version 2.100.0 (2026-02-01)" "$("${UPGRADE_DIR}/gh" --version)"
    check "verified update leaves no backup or staging dir" "" "$(find "${UPGRADE_DIR}" -name '.gh-*')"
fi

UPDATE_HELP="$("${KIMO}" update --help)"
check_contains "update help documents --allow-system-path" "--allow-system-path" "${UPDATE_HELP}"
check_contains "update help documents 'update gh'" "update gh" "${UPDATE_HELP}"

# 3. Install status and shadowing protection
echo "[3] Install status and shadowing protections"
FAKE_BIN_DIR="${TMPDIR_GH}/fake_bin"
mkdir -p "${FAKE_BIN_DIR}"
cat > "${FAKE_BIN_DIR}/gh" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "--version" || "$1" == "version" ]]; then
    echo "gh version 2.99.0 (2026-01-01)"
    exit 0
fi
exit 0
FAKE
chmod +x "${FAKE_BIN_DIR}/gh"

# A) When gh is at ~/.local/bin/gh and already installed
FAKE_HOME="${TMPDIR_GH}/home"
mkdir -p "${FAKE_HOME}/.local/bin"
cp "${FAKE_BIN_DIR}/gh" "${FAKE_HOME}/.local/bin/gh"

INSTALL_EXISTS_OUT="$(HOME="${FAKE_HOME}" PATH="${FAKE_HOME}/.local/bin:${PATH}" "${KIMO}" install gh 2>&1 || true)"
check_contains "install reports already installed when present at dest" "GitHub CLI is already installed" "${INSTALL_EXISTS_OUT}"

# B) When gh is at an external path, refusing to shadow without --allow-system-path
EMPTY_HOME="${TMPDIR_GH}/empty_home"
mkdir -p "${EMPTY_HOME}"
SHADOW_OUT="$(HOME="${EMPTY_HOME}" PATH="${FAKE_BIN_DIR}:/usr/bin:/bin" "${KIMO}" install --force gh 2>&1 || true)"
SHADOW_RC=0
HOME="${EMPTY_HOME}" PATH="${FAKE_BIN_DIR}:/usr/bin:/bin" "${KIMO}" install --force gh >/dev/null 2>&1 || SHADOW_RC=$?

check "install --force gh refuses shadowing external binary" "1" "${SHADOW_RC}"
check_contains "refusing to replace or shadow message" "Error: refusing to replace or shadow GitHub CLI at" "${SHADOW_OUT}"

# 4. Inventory table & Doctor diagnostics
echo "[4] Inventory table and Doctor diagnostics"
INSTALL_LIST="$("${KIMO}" install list)"
check_match "install list contains gh entry" "gh[[:space:]]+(● INSTALLED|○ MISSING)" "${INSTALL_LIST}"
check_match "install list shows gh default launch model" "gh[[:space:]]+.*kalidroid-27b:latest" "${INSTALL_LIST}"

DOCTOR_OUT="$("${KIMO}" doctor)"
check_match "doctor includes gh in External LLM CLI Hub Inventory" "\[(✓|·)\] gh[[:space:]]+:" "${DOCTOR_OUT}"

# 5. Shell completions
echo "[5] Shell completions (bash & zsh)"
BASH_COMP="$("${KIMO}" completion bash)"
check_match "bash completion lists gh among supported CLIs" 'supported_clis="[^"]* gh"' "${BASH_COMP}"
check_contains "bash completion offers supported CLIs for install" '${supported_clis} all list' "${BASH_COMP}"
check_contains "bash completion offers supported CLIs for update" '${supported_clis} all"' "${BASH_COMP}"
check_contains "bash completion includes --allow-system-path" '--allow-system-path' "${BASH_COMP}"

ZSH_COMP="$("${KIMO}" completion zsh)"
check_contains "zsh completion includes gh in install args" 'gh all list' "${ZSH_COMP}"
check_contains "zsh completion includes gh in update args" 'gh all' "${ZSH_COMP}"
check_contains "zsh completion includes --allow-system-path" '--allow-system-path' "${ZSH_COMP}"
check_contains "zsh completion includes gh in launch args" "openclaw hermes gh)' \\" "${ZSH_COMP}"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# 6. Optional live turn: requires the real gh CLI
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: real GitHub CLI turn"
    # Live tier: real HOME, PATH, network and credentials (opt-in, not hermetic).
    harness_use_real_env
    REAL_GH="$(type -P gh 2>/dev/null || true)"
    if [[ -z "${REAL_GH}" ]]; then
        echo "  SKIP: real gh CLI not found on PATH"
    else
        LIVE_VER="$("${REAL_GH}" --version | head -n 1)"
        check_match "real gh reports valid semver" "^gh version [0-9]+\.[0-9]+\.[0-9]+" "${LIVE_VER}"

        # Test kimo's version parsing matches real gh
        PARSED_VER="$("${KIMO}" doctor | grep -E '\[✓\] gh' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//')"
        if [[ -n "${PARSED_VER}" && "${LIVE_VER}" == *"${PARSED_VER}"* ]]; then
            ok "kimo version resolution (${PARSED_VER}) matches live gh (${LIVE_VER})"
        else
            bad "kimo version resolution (${PARSED_VER}) does not match live gh (${LIVE_VER})"
        fi

        # Check update eligibility test turn with --check
        UPDATE_ELIGIBLE="$("${KIMO}" update gh --allow-system-path --check 2>&1 || true)"
        check_contains "kimo reports update eligibility for standalone gh" "eligible for an in-place update" "${UPDATE_ELIGIBLE}"
    fi
    echo
    echo "total: ${pass} passed, ${fail} failed"
fi

[[ "${fail}" -eq 0 ]]
