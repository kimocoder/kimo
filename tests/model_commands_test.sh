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

echo
harness_summary "model commands"
