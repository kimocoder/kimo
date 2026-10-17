#!/usr/bin/env bash
# tests/tunnel-smoke.sh - Smoke tests for remote Ollama SSH tunnel management
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${SCRIPT_DIR}/kimo"

echo "=== Running kimo tunnel smoke tests ==="

# 1. Help output
assert_ok "kimo tunnel --help displays usage" bash -c "${KIMO} tunnel --help | grep -qi 'kimo tunnel'"
assert_ok "kimo tunnel help displays usage" bash -c "${KIMO} tunnel help | grep -qi 'kimo tunnel'"

# 2. Status inspection
assert_ok "kimo tunnel status executes cleanly" bash -c "${KIMO} tunnel status | grep -qi 'Remote Ollama SSH Tunnel Status'"
assert_ok "kimo tunnel (default) executes status" bash -c "${KIMO} tunnel | grep -qi 'Local Port'"

# 3. Status JSON output
assert_ok "kimo tunnel status --json emits valid JSON" bash -c "${KIMO} tunnel status --json | jq -e '.port == 11438 and .service and (.endpoint != null)' >/dev/null"

# 4. Setup unit template generation
assert_ok "kimo tunnel setup renders systemd unit template" bash -c "${KIMO} tunnel setup gpu.internal | grep -qi 'ollama-remote-tunnel.service'"

# 5. Invalid option fails gracefully
assert_ok "kimo tunnel --invalid-opt exits non-zero" bash -c "! ${KIMO} tunnel --invalid-opt >/dev/null 2>&1"

echo ""
harness_summary "Tunnel smoke test results"
