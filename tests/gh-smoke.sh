#!/usr/bin/env bash
# Headless smoke tests for kimo's GitHub CLI ('gh') integration.
#
# Asserts the contract for 'gh' in kimo across launch, install, update, doctor, and completions:
#   * Launch rejection contract: 'kimo launch gh' rejects execution because gh is a
#     management-only CLI rather than an LLM model runner.
#   * Install status contract:
#       - 'kimo install gh' reports existing binary when already installed.
#       - 'kimo install --force gh' refuses to replace/shadow an external system binary without --allow-system-path.
#   * Update flag contract:
#       - rejects combining --check and --apply
#       - restricts --allow-system-path strictly to named 'update gh' (not batch 'update all')
#       - validates update --help documentation and eligible check behavior
#   * Inventory & Doctor contract:
#       - 'kimo install list' includes 'gh' row marked with 'n/a' default model
#       - 'kimo doctor' detects 'gh' and formats its version and binary location
#   * Shell completion contract: bash & zsh completions expose 'gh' across install and update.
#
# Optional live layer (--live): if a real 'gh' binary is installed on the host, runs
# a real version verification check.
#
# Usage: tests/gh-smoke.sh [--live]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

TMPDIR_GH="$(mktemp -d)"
cleanup() { rm -rf "${TMPDIR_GH}"; }
trap cleanup EXIT

pass=0
fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

check() { # <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi
}

check_contains() { # <description> <needle> <haystack>
    if [[ "$3" == *"$2"* ]]; then
        ok "$1"
    else
        bad "$1: output did not contain '$2'"
    fi
}

check_match() { # <description> <regex> <actual>
    if [[ "$3" =~ $2 ]]; then
        ok "$1"
    else
        bad "$1: output did not match '$2'"
    fi
}

echo "=== Kimo GitHub CLI ('gh') Smoke Tests ==="

# 1. Launch rejection contract
echo "[1] Launch rejection contract (gh is management-only)"
LAUNCH_OUT="$("${KIMO}" launch gh --model kalidroid-27b:latest 2>&1 || true)"
LAUNCH_RC=0
"${KIMO}" launch gh --model kalidroid-27b:latest >/dev/null 2>&1 || LAUNCH_RC=$?

check "launch gh exits with status 1" "1" "${LAUNCH_RC}"
check_contains "launch gh error message" "Error: GitHub CLI is management-only; run gh directly, not through Ollama launch." "${LAUNCH_OUT}"

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
SHADOW_OUT="$("${KIMO}" install --force gh 2>&1 || true)"
SHADOW_RC=0
"${KIMO}" install --force gh >/dev/null 2>&1 || SHADOW_RC=$?

check "install --force gh refuses shadowing external binary" "1" "${SHADOW_RC}"
check_contains "refusing to replace or shadow message" "Error: refusing to replace or shadow GitHub CLI at" "${SHADOW_OUT}"

# 4. Inventory table & Doctor diagnostics
echo "[4] Inventory table and Doctor diagnostics"
INSTALL_LIST="$("${KIMO}" install list)"
check_match "install list contains gh entry" "gh[[:space:]]+(● INSTALLED|○ MISSING)" "${INSTALL_LIST}"
check_match "install list marks gh default model as n/a" "gh[[:space:]]+.*n/a" "${INSTALL_LIST}"

DOCTOR_OUT="$("${KIMO}" doctor)"
check_match "doctor includes gh in External LLM CLI Hub Inventory" "\[(✓|·)\] gh[[:space:]]+:" "${DOCTOR_OUT}"

# 5. Shell completions
echo "[5] Shell completions (bash & zsh)"
BASH_COMP="$("${KIMO}" completion bash)"
check_contains "bash completion allows gh in install target" 'gh all list' "${BASH_COMP}"
check_contains "bash completion allows gh in update target" 'gh all' "${BASH_COMP}"
check_contains "bash completion includes --allow-system-path" '--allow-system-path' "${BASH_COMP}"

ZSH_COMP="$("${KIMO}" completion zsh)"
check_contains "zsh completion includes gh in install args" 'gh all list' "${ZSH_COMP}"
check_contains "zsh completion includes gh in update args" 'gh all' "${ZSH_COMP}"
check_contains "zsh completion includes --allow-system-path" '--allow-system-path' "${ZSH_COMP}"

echo
echo "mocked smoke: ${pass} passed, ${fail} failed"

# 6. Optional live turn: requires the real gh CLI
if [[ "${LIVE}" -eq 1 ]]; then
    echo
    echo "[*] live: real GitHub CLI turn"
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
