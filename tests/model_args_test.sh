#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- model_args_test.sh ----------
# Model commands must treat options as options, never as model names; `rm`
# must delete only an exact, confirmed name; value-taking options must fail
# with a usage error; secrets and locks must stay out of argv and shared /tmp.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
WORK="$(mktemp -d)"

harness_fake_ollama
URL="${FAKE_OLLAMA_URL}"
requests() { cat "${FAKE_OLLAMA_LOG}" 2>/dev/null || true; }

# 1) --help prints usage and sends nothing to the server.
for cmd in rm info warm tag stop run tune; do
    rc=0
    out=$("${KIMO}" --host "${URL}" "${cmd}" --help 2>&1 </dev/null) || rc=$?
    check "${cmd} --help exits 0" "0" "${rc}"
    check_contains "${cmd} --help prints usage" "Usage: kimo ${cmd}" "${out}"
done
rc=0
out=$("${KIMO}" --host "${URL}" info fixture-model --help 2>&1) || rc=$?
check_contains "info <model> --help prints usage" "Usage: kimo info" "${out}"
rc=0
out=$("${KIMO}" --host "${URL}" rm -x fixture-model 2>&1 </dev/null) || rc=$?
check "rm rejects an unknown option" "1" "${rc}"
check_contains "rm names the unknown option" "unknown option '-x'" "${out}"
check_not_contains "--help and bad options reach no endpoint" "/api/" "$(requests)"

# 2) rm deletes only an exact installed name, and only when confirmed.
rc=0
out=$("${KIMO}" --host "${URL}" rm fixture-model 2>&1 </dev/null) || rc=$?
check "rm without a terminal or --yes refuses" "1" "${rc}"
check_contains "rm explains how to confirm" "pass --yes" "${out}"
rc=0
out=$("${KIMO}" --host "${URL}" rm fixture --yes 2>&1) || rc=$?
check "rm of a prefix-only name fails" "1" "${rc}"
check_contains "rm requires the exact name" "exact name required" "${out}"
rc=0
"${KIMO}" --host "${URL}" rm missing-model -y >/dev/null 2>&1 || rc=$?
check "rm of a missing model fails" "1" "${rc}"
check_not_contains "no delete was sent before confirmation" "/api/delete" "$(requests)"
rc=0
out=$("${KIMO}" --host "${URL}" rm fixture-model --yes 2>&1) || rc=$?
check "rm --yes of an exact name succeeds" "0" "${rc}"
check_contains "rm deletes the resolved :latest tag" '"name":"fixture-model:latest"' "$(requests)"
rc=0
out=$("${KIMO}" --host http://127.0.0.1:9 --host "${URL}" rm fixture-model --yes 2>&1) || rc=$?
check "rm with several --host values succeeds" "0" "${rc}"
check_contains "rm goes to the host that has the model" "from ${URL}" "${out}"

# 3) Negative durations are values, not options (keep_alive -1 = forever).
harness_reset_stub_log
: > "${FAKE_OLLAMA_LOG}"
"${KIMO}" --host "${URL}" warm fixture-model -1 >/dev/null 2>&1 || true
check_contains "warm <model> -1 reaches the server" '"keep_alive":"-1"' "$(requests)"

# 4) A value-taking option given last is a usage error, not a crash or hang.
for args in "tune fixture-model --ctx" "freetier --limit" "top -n" "ps --interval"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(timeout 10 "${KIMO}" --host "${URL}" ${args} 2>&1 </dev/null) || rc=$?
    check "'${args}' exits 1" "1" "${rc}"
    check_contains "'${args}' explains the missing value" "requires a value" "${out}"
    check_not_contains "'${args}' does not hit set -u" "unbound variable" "${out}"
done

# 5) curl_bearer sends the header from stdin config (escaping quotes), so the
#    key never appears in curl's argv.
eval "$(sed -n '/^curl_bearer() {/,/^}/p' "${KIMO}")"
sent=$(curl_bearer 'k"e\y' -sv -o /dev/null "${URL}/api/version" 2>&1 | tr -d '\r' | grep -i '^> authorization' || true)
check "curl_bearer sends the escaped key" '> Authorization: Bearer k"e\y' "${sent}"
check_not_contains "no Bearer header is built on a kimo curl command line" \
    'curl[^|]*-H "Authorization: Bearer' "$(grep -E 'curl[^|]*-H "Authorization: Bearer \$\{(key|tok)\}' "${KIMO}" || true)"

# 6) Claims and locks live in a private per-user directory.
eval "$(sed -n '/^ensure_private_dir() {/,/^}/p' "${KIMO}")"
# shellcheck disable=SC2034  # read by the eval'd ensure_private_dir
C_RED="" C_RESET=""
rc=0
ensure_private_dir "${WORK}/rt" || rc=$?
check "ensure_private_dir creates the directory" "0" "${rc}"
check "the new directory is mode 700" "700" "$(stat -c %a "${WORK}/rt")"
mkdir "${WORK}/elsewhere"
ln -s "${WORK}/elsewhere" "${WORK}/link"
rc=0
ensure_private_dir "${WORK}/link" 2>/dev/null || rc=$?
check "ensure_private_dir rejects a symlink" "1" "${rc}"
if [[ "$(id -u)" == "0" ]] && id nobody >/dev/null 2>&1; then
    mkdir "${WORK}/foreign"
    chown nobody "${WORK}/foreign"
    rc=0
    ensure_private_dir "${WORK}/foreign" 2>/dev/null || rc=$?
    check "ensure_private_dir rejects another user's directory" "1" "${rc}"
fi
check_not_contains "no lock or claim default is a fixed /tmp name" "/tmp}/kimo-" \
    "$(grep -E '^(AGY_CLAIM_DIR|GROK_CLAIM_DIR|KIMI_CONFIG_LOCK)=' "${KIMO}")"
check "locks are opened without truncation" "" \
    "$(grep -E 'exec [0-9]>"\$\{KIMI_CONFIG_LOCK\}"' "${KIMO}" || true)"

# 7) rm takes several models: all are resolved first, one missing name aborts
#    before anything is deleted, then each is deleted from its own host.
harness_fake_ollama --models "alpha:latest,beta:7b"
HOST_A="${FAKE_OLLAMA_URL}" LOG_A="${FAKE_OLLAMA_LOG}"
harness_fake_ollama --models "gamma:latest"
HOST_B="${FAKE_OLLAMA_URL}" LOG_B="${FAKE_OLLAMA_LOG}"
rc=0
out=$("${KIMO}" --host "${HOST_A}" rm alpha nope -y 2>&1) || rc=$?
check "rm with one missing model fails" "1" "${rc}"
check_contains "rm names the missing model" "nope" "${out}"
check_not_contains "nothing is deleted when one name is missing" "/api/delete" "$(cat "${LOG_A}")"
rc=0
out=$("${KIMO}" --host "${HOST_A}" --host "${HOST_B}" rm alpha beta:7b gamma --yes 2>&1) || rc=$?
check "rm of three models on two hosts succeeds" "0" "${rc}"
check "host A got two deletes" "2" "$(grep -c 'DELETE /api/delete' "${LOG_A}" || true)"
check "host B got one delete" "1" "$(grep -c 'DELETE /api/delete' "${LOG_B}" || true)"
check_contains "gamma was deleted on host B" '"name":"gamma:latest"' "$(cat "${LOG_B}")"
rc=0
out=$("${KIMO}" --host "${HOST_A}" rm alpha beta:7b 2>&1 </dev/null) || rc=$?
check "rm of several models without --yes refuses" "1" "${rc}"
check_contains "the refusal lists every model" "beta:7b" "${out}"

# 8) default_model (config or KIMO_DEFAULT_MODEL) drives launch and run;
#    -m still wins and the per-CLI preset is the last resort.
mkdir -p "${WORK}/fakebin"
cat > "${WORK}/fakebin/qwen" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${QWEN_ARGS_OUT:?}"
FAKE
chmod +x "${WORK}/fakebin/qwen"
export QWEN_ARGS_OUT="${WORK}/qwen.args"
launched_model() { # <kimo args...>
    rm -f "${QWEN_ARGS_OUT}"
    PATH="${WORK}/fakebin:${PATH}" "${KIMO}" --host http://127.0.0.1:9 "$@" >/dev/null 2>&1 </dev/null || true
    grep -A1 -x -- '--model' "${QWEN_ARGS_OUT}" 2>/dev/null | tail -n1
}
printf 'default_model=my-default:latest\n' > "${WORK}/cfg"
check "config default_model drives launch" "my-default:latest" \
    "$(KIMO_CONFIG_FILE="${WORK}/cfg" launched_model launch qwen)"
check "KIMO_DEFAULT_MODEL beats the config file" "env-model:1b" \
    "$(KIMO_CONFIG_FILE="${WORK}/cfg" KIMO_DEFAULT_MODEL=env-model:1b launched_model launch qwen)"
check "-m beats default_model" "explicit:3b" \
    "$(KIMO_CONFIG_FILE="${WORK}/cfg" launched_model launch qwen -m explicit:3b)"
: > "${WORK}/empty-cfg"
check "without default_model the per-CLI preset is used" "qwen3.8:latest" \
    "$(KIMO_CONFIG_FILE="${WORK}/empty-cfg" launched_model launch qwen)"
out=$(KIMO_CONFIG_FILE="${WORK}/cfg" timeout 10 "${KIMO}" --host http://127.0.0.1:9 run 2>&1 </dev/null || true)
check_contains "run without a model uses default_model" "my-default:latest" "${out}"
out=$(KIMO_CONFIG_FILE="${WORK}/cfg" "${KIMO}" config list 2>&1)
check_contains "config list shows the effective default model" "my-default:latest" "${out}"

rm -rf "${WORK}"
harness_summary "model_args_test.sh"
