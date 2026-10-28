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

echo "[*] tune merges options, validates values and never clobbers the store"
TUNE() { "${KIMO}" --host "${LOCAL_URL}" tune "$@"; }
tuned() { jq -cS --arg m "$1" '.[$m]' "${KIMO_TUNINGS_FILE}"; }
printf '{"localonly:latest": {"num_ctx": 4096}, "other:7b": {"num_ctx": 2048}}\n' >"${KIMO_TUNINGS_FILE}"
TUNE localonly:latest --temp 0.2 >/dev/null 2>&1 || bad "tune --temp failed"
check "a second tune keeps the earlier option" '{"num_ctx":4096,"temperature":0.2}' "$(tuned localonly:latest)"
TUNE localonly:latest --ctx 8192 >/dev/null 2>&1 || bad "tune --ctx failed"
check "a repeated option is updated in place" '{"num_ctx":8192,"temperature":0.2}' "$(tuned localonly:latest)"
check "other models' tunings are untouched" '{"num_ctx":2048}' "$(tuned other:7b)"
before=$(cat "${KIMO_TUNINGS_FILE}")
for bad_args in "--ctx abc" "--ctx -5" "--ctx 0" "--batch 1.5" "--predict x" "--num-gpu -2" "--num-gpu x" "--temp -1" "--temp hot"; do
    rc=0
    # shellcheck disable=SC2086  # word-split the option and its value
    out=$(TUNE localonly:latest ${bad_args} 2>&1) || rc=$?
    check "tune rejects ${bad_args}" "1" "${rc}"
    check_not_contains "tune ${bad_args} is an error, not a traceback" "Traceback" "${out}"
done
check "rejected values leave the store unchanged" "${before}" "$(cat "${KIMO_TUNINGS_FILE}")"
TUNE localonly:latest --num-gpu -1 >/dev/null 2>&1 || bad "tune --num-gpu -1 failed"
check "--num-gpu -1 (auto) is accepted" "-1" "$(jq -r '."localonly:latest".num_gpu' "${KIMO_TUNINGS_FILE}")"

# 'kimo stream --tune' takes the same lock, so the two writers serialize.
python3 - "${KIMO_TUNINGS_FILE}.lock" "${HARNESS_ROOT}/lock-held" <<'PY' &
import fcntl, sys, time
with open(sys.argv[1], "a") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    open(sys.argv[2], "w").close()
    time.sleep(1.0)
PY
holder=$!
until [[ -e "${HARNESS_ROOT}/lock-held" ]]; do sleep 0.02; done
start=$(date +%s%N)
TUNE localonly:latest --batch 512 >/dev/null 2>&1 || bad "tune --batch failed"
waited_ms=$(( ($(date +%s%N) - start) / 1000000 ))
wait "${holder}"
check "tune waits for the tunings lock" "yes" "$( ((waited_ms >= 700)) && echo yes || echo "no (${waited_ms}ms)")"

out=$(TUNE localonly:latest --clear 2>&1) || bad "tune --clear failed"
check_contains "--clear reports the removal" "Cleared tuned defaults" "${out}"
check "--clear removes only that model" '["other:7b"]' "$(jq -c 'keys' "${KIMO_TUNINGS_FILE}")"
rc=0
out=$(TUNE localonly:latest --clear 2>&1) || rc=$?
check "--clear with nothing registered succeeds" "0" "${rc}"
check_not_contains "--clear with nothing registered does not claim a removal" "Cleared" "${out}"

printf 'not json' >"${KIMO_TUNINGS_FILE}"
for args in "--clear" "--ctx 4096"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(TUNE localonly:latest ${args} 2>&1) || rc=$?
    check "tune ${args} on a corrupt store fails" "1" "${rc}"
    check_not_contains "tune ${args} on a corrupt store gives no traceback" "Traceback" "${out}"
    check_not_contains "tune ${args} on a corrupt store claims no success" "[✓]" "${out}"
    check "tune ${args} leaves a corrupt store as it was" "not json" "$(cat "${KIMO_TUNINGS_FILE}")"
done

echo "[*] stream --clear-tuning clears exactly the named model"
STREAM_TUNINGS="${HARNESS_ROOT}/stream-tunings.json"
CLEAR() { KIMO_TUNINGS_FILE="${STREAM_TUNINGS}" python3 "${ROOT_DIR}/lib/kimo-stream.py" "$@" --clear-tuning; }
printf '{"my-llama-coder:7b": {"num_ctx": 1}, "qwen3:8b": {"num_ctx": 2}, "qwen3:14b": {"num_ctx": 3}, "phi4:latest": {"num_ctx": 4}}\n' >"${STREAM_TUNINGS}"
rc=0
CLEAR llama >/dev/null 2>&1 || rc=$?
check "a substring never matches ('llama' vs my-llama-coder:7b)" "1:4" "${rc}:$(jq 'length' "${STREAM_TUNINGS}")"
rc=0
out=$(CLEAR qwen3 --json 2>/dev/null) || rc=$?
check "a name with several tags is ambiguous and clears nothing" "1:ambiguous:4" "${rc}:$(jq -r '.status' <<<"${out}"):$(jq 'length' "${STREAM_TUNINGS}")"
CLEAR my-llama-coder >/dev/null 2>&1 || bad "clearing a uniquely tagged name failed"
check "a name with one tag clears that tag" "false" "$(jq 'has("my-llama-coder:7b")' "${STREAM_TUNINGS}")"
CLEAR phi4 >/dev/null 2>&1 || bad "clearing name:latest failed"
CLEAR QWEN3:8B >/dev/null 2>&1 || bad "clearing a case-insensitive exact name failed"
check "':latest' and case-insensitive exact names clear just that entry" '["qwen3:14b"]' "$(jq -c 'keys' "${STREAM_TUNINGS}")"

echo
harness_summary "model commands"
