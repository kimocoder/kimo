#!/usr/bin/env bash
# Core model commands against two fake Ollama hosts (local + remote): host
# routing (--local / --remote / both) and per-host state in the output.
#
# Usage: tests/model_commands_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# 'shared' exists on both hosts but is resident only on the remote one.
harness_fake_ollama --models "localonly:latest,shared:latest"
LOCAL_URL="${FAKE_OLLAMA_URL}" LOCAL_LOG="${FAKE_OLLAMA_LOG}"
harness_fake_ollama --models "remoteonly:latest,shared:latest" --loaded "shared:latest"
REMOTE_URL="${FAKE_OLLAMA_URL}" REMOTE_LOG="${FAKE_OLLAMA_LOG}"
export OLLAMA_LOCAL_URL="${LOCAL_URL}" OLLAMA_REMOTE_URL="${REMOTE_URL}"
mkdir -p "$(dirname "${KIMO_TUNINGS_FILE}")"
printf '{"localonly:latest": {"num_ctx": 4096}}\n' >"${KIMO_TUNINGS_FILE}"

rows() { # <kimo args...> -> "host name active tuned" per JSON row, sorted
    "${KIMO}" "$@" --json 2>/dev/null | python3 -c '
import json, sys
for r in sorted(json.load(sys.stdin), key=lambda r: (r["host"], r["name"])):
    print(r["host"], r["name"], "active" if r["active"] else "-", "tuned" if r["tuned"] else "-")'
}

echo "[*] search honors the host mode"
: >"${REMOTE_LOG}"
out=$(rows --local search only)
check "--local lists only local models" "local localonly:latest - tuned" "${out}"
check "--local never queries the remote host" "" "$(cat "${REMOTE_LOG}")"
: >"${LOCAL_LOG}"
out=$(rows --remote search only)
check "--remote lists only remote models" "remote remoteonly:latest - -" "${out}"
check "--remote never queries the local host" "" "$(cat "${LOCAL_LOG}")"

echo "[*] search reports residency per host"
out=$(rows search shared)
check "a model resident on the remote host is not ACTIVE locally" \
    "$(printf 'local shared:latest - -\nremote shared:latest active -')" "${out}"

echo "[*] stream runs the shipped helper with kimo's remote resolution"
# The default lookup must not depend on anything outside the checkout.
check "kimo does not reference /root/stream_model.py" "0" \
    "$(grep -c '/root/stream_model\.py' "${KIMO}" || true)"
STUB="${HARNESS_ROOT}/stream-stub.py" STUB_LOG="${HARNESS_ROOT}/stream-stub.log"
cat >"${STUB}" <<'PY'
import json, os, sys
with open(os.environ["STUB_LOG"], "w") as fh:
    json.dump({"argv": sys.argv[1:], "tunnel": os.environ.get("KIMO_REMOTE_TUNNEL_URL"),
               "tunings": os.environ.get("KIMO_TUNINGS_FILE")}, fh)
PY
rc=0
STUB_LOG="${STUB_LOG}" KIMO_STREAM_HELPER="${STUB}" "${KIMO}" --remote --json stream --status >/dev/null 2>&1 || rc=$?
check "stream exits with the helper's status" "0" "${rc}"
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(d["argv"]), "|", d["tunings"])' "${STUB_LOG}")
check "argv carries --json, the chosen remote and the subcommand" \
    "--json --remote ${REMOTE_URL} --status | ${KIMO_TUNINGS_FILE}" "${got}"

echo "[*] bench measures first-token latency from the client, load included"
# The fixture's first generate for a model pays a 0.5s cold load, and every
# reply waits 0.1s before its first token; prefill reports 20ms.
harness_fake_ollama --models "bench-model:latest"
BENCH_URL="${FAKE_OLLAMA_URL}" BENCH_LOG="${FAKE_OLLAMA_LOG}"
bench=$("${KIMO}" --host "${BENCH_URL}" --json bench bench-model:latest -n 3 2>/dev/null)
field() { jq -r "$1" <<<"${bench}"; }
check "a cold run reports the model load" "500" "$(field '.load_ms | floor')"
check "TTFT covers the cold load, not just the 20ms prefill" "yes" \
    "$(field 'if .time_to_first_token_ms >= 550 then "yes" else "no (\(.time_to_first_token_ms))" end')"
check "prefill keeps its own figure" "20" "$(field '.prompt_eval.duration_ms | floor')"

bench=$("${KIMO}" --host "${BENCH_URL}" --json bench bench-model:latest -n 3 --runs 3 --warmup 2>/dev/null)
check "--runs keeps one result per timed run" "3" "$(field '.results | length')"
check "--warmup is untimed and the timed runs load nothing" "0" "$(field '[.results[].load_ms] | max | floor')"
check "a warm TTFT is the reply latency" "yes" \
    "$(field 'if .stats.time_to_first_token_ms.max < 550 then "yes" else "no" end')"
prompts=$(grep '^POST /api/generate ' "${BENCH_LOG}" | tail -n 4 | sed 's/^POST \/api\/generate //' | jq -r '.prompt | split("\n")[0]' | sort -u | wc -l)
check "every request gets a distinct prompt, so no prefix cache is reused" "4" "$(tr -d ' ' <<<"${prompts}")"

rc=0
out=$("${KIMO}" --host "${BENCH_URL}" bench --runs 0 2>&1) || rc=$?
check "--runs rejects non-positive counts" "1" "${rc}"
rc=0
out=$(KIMO_DEFAULT_MODEL="" "${KIMO}" --host "${BENCH_URL}" bench 2>&1) || rc=$?
check "no model and none loaded is an error, not a hardcoded default" "1" "${rc}"
check_contains "the error says how to pick a model" "config set default_model" "${out}"

echo
harness_summary "model commands"
