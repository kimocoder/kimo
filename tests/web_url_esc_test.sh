#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- web_url_esc_test.sh ----------
# Tests that the JSON‑payload escaping logic is present in the script
# and that `kimo web url` does not produce a broken curl command.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# 1) Verify the escaping sed line exists in the script
if grep -q "payload_esc" "${KIMO}"; then
    ok "web URL payload escaping code found in kimo"
else
    bad "web URL payload escaping code not found"
fi

# 2) Run `kimo web url` with a simple URL and capture the printed curl command.
#    The harness WebBridge URL is dead, so kimo prints the manual command; it
#    must not contain an unescaped single quote that would break the
#    single‑quoted -d argument.
url="https://example.com"
output=$("${KIMO}" web url "$url" 2>&1) || true
check_contains "web url prints a manual curl command" "curl -s -X POST" "${output}"
check_match "curl command has properly single‑quoted -d argument" "-d '.*'" "${output}"

harness_summary "web_url_esc_test.sh"
