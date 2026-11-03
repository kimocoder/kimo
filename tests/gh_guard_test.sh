#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- gh_guard_test.sh ----------
# Tests that `kimo run gh` rejects 'gh' as a model name and points at
# `kimo launch gh` (GitHub Copilot CLI), which is the supported route.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

echo "Testing 'kimo run gh' ..."
rc=0
output=$("${KIMO}" run gh 2>&1) || rc=$?
check_contains "kimo run gh says gh is not a model" "'gh' is the GitHub CLI, not a model" "${output}"
check_contains "kimo run gh points at launch gh" "launch gh" "${output}"
check "kimo run gh exits 1" "1" "${rc}"

harness_summary "gh_guard_test.sh"
