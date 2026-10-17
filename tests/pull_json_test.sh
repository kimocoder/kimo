#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- pull_json_test.sh ----------
# Tests for the `--json` flag on `kimo pull`. The pull runs against the
# harness's fake Ollama fixture, never a real daemon or registry.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# 1) Verify that the help output lists --json
help_output=$("${KIMO}" pull --help 2>&1)
check_contains "--json appears in pull help" "--json" "${help_output}"

# 2) `kimo pull --json` without a model name exits non-zero with a usage error
rc=0
output=$("${KIMO}" pull --json 2>&1) || rc=$?
check_contains "pull --json without model shows proper error" "requires a model name" "${output}"
check "pull --json without model exits 1" "1" "${rc}"

# 3) Streamed progress from a fixture daemon: every stdout line is JSON and the
#    stream ends in a success event.
harness_fake_ollama
rc=0
json_out=$("${KIMO}" --host "${FAKE_OLLAMA_URL}" pull fixture-model --json 2>/dev/null) || rc=$?
check "pull --json against the fixture exits 0" "0" "${rc}"
invalid=$(printf '%s\n' "${json_out}" | python3 -c '
import json, sys
bad = 0
for line in sys.stdin:
    if line.strip():
        try:
            json.loads(line)
        except ValueError:
            bad += 1
print(bad)')
check "every pull --json line is valid JSON" "0" "${invalid}"
last_status=$(printf '%s\n' "${json_out}" | tail -n1 | jq -r '.status // empty' 2>/dev/null || true)
check "pull --json stream ends with success" "success" "${last_status}"
check_contains "the pull request reached the fixture" "POST /api/pull" "$(cat "${FAKE_OLLAMA_LOG}")"
assert_no_stub_calls "no real ollama binary was invoked" ollama

# 4) Failures must exit non-zero in both modes: an error event mid-stream and a
#    stream that stops before the final success event.
EVENTS_DIR="$(mktemp -d)"
printf '%s\n' '{"status":"pulling manifest"}' '{"error":"fixture download denied"}' > "${EVENTS_DIR}/error.ndjson"
printf '%s\n' '{"status":"pulling manifest"}' \
    '{"status":"pulling x","digest":"sha256:aaaaaaaaaaaaaaaa","total":100,"completed":40}' > "${EVENTS_DIR}/truncated.ndjson"
harness_fake_ollama --pull-events "${EVENTS_DIR}/error.ndjson"
ERROR_URL="${FAKE_OLLAMA_URL}"
harness_fake_ollama --pull-events "${EVENTS_DIR}/truncated.ndjson"
TRUNC_URL="${FAKE_OLLAMA_URL}"

rc=0
out=$("${KIMO}" --host "${ERROR_URL}" pull fixture-model --json 2>"${EVENTS_DIR}/err") || rc=$?
check "--json: error event exits 1" "1" "${rc}"
check_contains "--json: the error event is still printed as JSON" '"error": "fixture download denied"' "${out}"
check_contains "--json: the error is explained on stderr" "fixture download denied" "$(cat "${EVENTS_DIR}/err")"

rc=0
"${KIMO}" --host "${ERROR_URL}" pull fixture-model >/dev/null 2>&1 || rc=$?
check "text: error event exits 1" "1" "${rc}"

for mode in --json ""; do
    rc=0
    err=$("${KIMO}" --host "${TRUNC_URL}" pull fixture-model ${mode} 2>&1 >/dev/null) || rc=$?
    check "${mode:-text}: truncated stream exits 1" "1" "${rc}"
    check_contains "${mode:-text}: truncated stream is reported" "ended before the server reported success" "${err}"
done

# 5) On a terminal, progress redraws one line instead of printing a new line
#    per event: six events for one layer must not produce six lines.
printf '%s\n' '{"status":"pulling manifest"}' \
    '{"status":"pulling x","digest":"sha256:bbbbbbbbbbbbbbbb","total":2147483648,"completed":0}' \
    '{"status":"pulling x","digest":"sha256:bbbbbbbbbbbbbbbb","total":2147483648,"completed":536870912}' \
    '{"status":"pulling x","digest":"sha256:bbbbbbbbbbbbbbbb","total":2147483648,"completed":1073741824}' \
    '{"status":"pulling x","digest":"sha256:bbbbbbbbbbbbbbbb","total":2147483648,"completed":1610612736}' \
    '{"status":"pulling x","digest":"sha256:bbbbbbbbbbbbbbbb","total":2147483648,"completed":2147483648}' \
    '{"status":"success"}' > "${EVENTS_DIR}/progress.ndjson"
harness_fake_ollama --pull-events "${EVENTS_DIR}/progress.ndjson"
TTY_OUT=$(python3 - "${KIMO}" "${FAKE_OLLAMA_URL}" <<'PY'
import os, pty, sys
kimo, host = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(kimo, [kimo, "--host", host, "--no-color", "pull", "fixture-model"])
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
PY
)
progress_lines=$(printf '%s' "${TTY_OUT}" | tr -d '\r' | grep -c 'bbbbbbbbbbbb' || true)
check "TTY: one finished progress line for one layer" "1" "${progress_lines}"
check_contains "TTY: progress redraws in place with carriage returns" $'\r' "${TTY_OUT}"
check_contains "TTY: sizes are human-readable" "2.0 GiB/2.0 GiB" "${TTY_OUT}"
check_contains "TTY: success is reported" "Successfully pulled model 'fixture-model'" "${TTY_OUT}"

harness_summary "pull_json_test.sh"
