#!/usr/bin/env bash
# Installer supply-chain guard: kimo only ever asks npm/pip for the official
# package of each CLI, and never falls back to a look-alike name when that
# install fails (the harness npm/pip stubs fail every install).
#
#   codex  -> @openai/codex only (unscoped npm 'codex' is an unrelated project)
#   hermes -> PyPI hermes-agent only (npm 'hermes-agent' is an unofficial bridge)
#
# Usage: tests/install_packages_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

echo "[*] codex"
harness_reset_stub_log
"${KIMO}" install codex --force >/dev/null 2>&1 || true
npm_calls="$(harness_stub_calls npm)"
check "codex installs the scoped package once" "npm install -g @openai/codex" "${npm_calls}"
check_not_contains "codex never falls back to unscoped 'codex'" "install -g codex" "${npm_calls}"

echo "[*] hermes"
harness_reset_stub_log
"${KIMO}" install hermes --force >/dev/null 2>&1 || true
assert_no_stub_calls "hermes never uses npm" npm
check_contains "hermes installs from PyPI" "pip install hermes-agent" "$(harness_stub_calls pip)"

echo "[*] update lookups"
# The version feeds must not consult the look-alike packages either.
check_not_contains "no 'npm view codex' lookup" "npm view codex " "$(cat "${KIMO}")"
check_not_contains "no npm hermes-agent lookup" "npm view hermes-agent" "$(cat "${KIMO}")"

echo
harness_summary "install packages"
