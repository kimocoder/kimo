#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- jq_guard_test.sh ----------
# Tests that kimo check/scan/config error out when jq is not available.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# A PATH with the harness stubs plus every system binary except jq.
FAKE_BIN=$(mktemp -d)
for p in "${HARNESS_STUB_DIR}"/* /bin/* /usr/bin/*; do
    [[ -x "$p" ]] || continue
    bn="$(basename "$p")"
    [[ "$bn" == "jq" ]] && continue
    [[ -e "${FAKE_BIN}/${bn}" ]] && continue
    ln -s "$p" "${FAKE_BIN}/${bn}" 2>/dev/null || true
done

for cmd in check scan config; do
    echo "Testing 'kimo $cmd' without jq ..."
    rc=0
    output=$(PATH="${FAKE_BIN}" KIMO_ENFORCE_PATH=0 "${KIMO}" "$cmd" 2>&1) || rc=$?
    check_contains "kimo $cmd reports missing jq" "jq is required" "${output}"
    check "kimo $cmd exits 1 without jq" "1" "${rc}"
done

harness_summary "jq_guard_test.sh"
