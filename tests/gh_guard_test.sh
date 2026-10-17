#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- gh_guard_test.sh ----------
# Tests that both `kimo launch gh` and `kimo run gh` reject the command
# with the proper "management-only" error message.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

for verb in launch run; do
    echo "Testing 'kimo ${verb} gh' ..."
    rc=0
    output=$("${KIMO}" "${verb}" gh 2>&1) || rc=$?
    check_contains "kimo ${verb} gh shows management-only error" "GitHub CLI is management-only" "${output}"
    check "kimo ${verb} gh exits 1" "1" "${rc}"
done

harness_summary "gh_guard_test.sh"
