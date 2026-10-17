#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# tests/rotate_token_test.sh - Smoke tests for kimo rotate-token command
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
export PATH="${ROOT_DIR}:${PATH}"
export KIMO_NO_AUTOSCAN=1

echo "=== Kimo Rotate Token Smoke Tests ==="

# 1. Help message
HELP_OUT=$("${KIMO}" rotate-token --help)
assert_match "rotate-token help mentions --show-token" "(--show-token)" "${HELP_OUT}"
assert_match "rotate-token help mentions --file" "(--file)" "${HELP_OUT}"
assert_match "rotate-token help mentions --domain" "(--domain)" "${HELP_OUT}"

# 2. Missing token file returns error
MISSING_FILE="${TMPDIR}/nonexistent-token-$RANDOM.token"
rc=0
ERR_OUT=$("${KIMO}" rotate-token --file "${MISSING_FILE}" -y 2>&1) || rc=$?
assert_eq "missing token file exits 1" "1" "${rc}"
assert_match "error mentions file not found" "(not found)" "${ERR_OUT}"

# 3. Rotate token with masking by default
TMP_DIR=$(mktemp -d)

TOKEN_FILE="${TMP_DIR}/test-api.token"
echo "token initial-secret-token-12345" > "${TOKEN_FILE}"

harness_reset_stub_log
OUT_MASKED=$("${KIMO}" rotate-token --file "${TOKEN_FILE}" --domain "test.internal" -y)
NEW_RAW=$(awk '{print $2}' "${TOKEN_FILE}")

assert_match "output reports token rotated" "(Token rotated in)" "${OUT_MASKED}"
assert_match "masked token output contains ellipsis" "new token: [A-Za-z0-9_-]{8}\.\.\.[A-Za-z0-9_-]{4}" "${OUT_MASKED}"
# Verify raw secret is NOT leaked on stdout when masked
RAW_LEAK=0
if [[ "${OUT_MASKED}" == *"${NEW_RAW}"* ]]; then
    RAW_LEAK=1
fi
assert_eq "raw token secret is masked by default" "0" "${RAW_LEAK}"

# Verify backup was created with initial token
BACKUP_TOKEN=$(awk '{print $2}' "${TOKEN_FILE}.bk")
assert_eq "backup file preserves previous token" "initial-secret-token-12345" "${BACKUP_TOKEN}"

# 4. Rotate token with --show-token displays plaintext
OUT_UNMASKED=$("${KIMO}" rotate-token --file "${TOKEN_FILE}" --domain "test.internal" --show-token -y)
NEW_RAW2=$(awk '{print $2}' "${TOKEN_FILE}")
assert_match "unmasked output displays full plaintext token" "${NEW_RAW2}" "${OUT_UNMASKED}"

# 5. An ad-hoc --file never re-renders the proxy or touches Apache
assert_no_stub_calls "ad-hoc --file runs no proxy render script" render-ollama-proxy.sh
assert_no_stub_calls "ad-hoc --file runs no apache2ctl" apache2ctl
assert_no_stub_calls "ad-hoc --file runs no systemctl" systemctl
assert_match "ad-hoc --file says the proxy was left alone" "(not re-rendered or reloaded)" "${OUT_MASKED}"

# 6. --reload opts back in: render, configtest and reload all go through the
#    harness stubs (systemctl reports apache2 active for this run).
harness_reset_stub_log
OUT_RELOAD=$(HARNESS_STUB_SYSTEMCTL_ACTIVE=0 "${KIMO}" rotate-token --file "${TOKEN_FILE}" --domain "test.internal" --reload -y)
assert_match "--reload rotation succeeds" "(Token rotated in)" "${OUT_RELOAD}"
check "--reload runs the proxy render script" "render-ollama-proxy.sh" "$(harness_stub_calls render-ollama-proxy.sh)"
check "--reload runs apache2ctl configtest" "apache2ctl configtest" "$(harness_stub_calls apache2ctl)"
check_contains "--reload reloads apache2" "systemctl reload apache2" "$(harness_stub_calls systemctl)"

# 7. The configured token file (no --file) keeps the proxy steps on by default
cp "${TOKEN_FILE}" "${KIMO_TOKEN_FILE}"
harness_reset_stub_log
"${KIMO}" rotate-token --domain "test.internal" -y >/dev/null
check "configured token file runs the proxy render script" "render-ollama-proxy.sh" "$(harness_stub_calls render-ollama-proxy.sh)"

# 8. --no-reload skips the proxy steps even for the configured file
harness_reset_stub_log
"${KIMO}" rotate-token --domain "test.internal" --no-reload -y >/dev/null
assert_no_stub_calls "--no-reload runs no proxy render script" render-ollama-proxy.sh
assert_no_stub_calls "--no-reload runs no systemctl" systemctl

# 9. A value-taking flag at the end of argv is an error, not an endless loop
for flag in --file --domain --render-script; do
    rc=0
    out=$(timeout 5 "${KIMO}" rotate-token -y "${flag}" 2>&1) || rc=$?
    check "${flag} without a value exits 1 (no hang)" "1" "${rc}"
    check_contains "${flag} without a value names the flag" "${flag} requires a value" "${out}"
done

# 10. Unknown options are rejected instead of falling back to production defaults
rc=0
out=$("${KIMO}" rotate-token --file "${TOKEN_FILE}" --no-verfy -y 2>&1) || rc=$?
check "typo'd option exits 1" "1" "${rc}"
check_contains "typo'd option is named" "unknown rotate-token option '--no-verfy'" "${out}"

# 11. A failed Apache reload rolls the token back and reports failure
BEFORE_RELOAD_FAIL=$(cat "${TOKEN_FILE}")
harness_reset_stub_log
rc=0
OUT_FAIL=$(HARNESS_STUB_SYSTEMCTL_ACTIVE=0 HARNESS_STUB_RC_systemctl=1 \
    "${KIMO}" rotate-token --file "${TOKEN_FILE}" --domain "test.internal" --reload -y 2>&1) || rc=$?
check "failed reload exits 1" "1" "${rc}"
check_contains "failed reload is reported" "Apache reload failed; rolled back" "${OUT_FAIL}"
check_not_contains "failed reload does not claim success" "Token rotated" "${OUT_FAIL}"
check "failed reload restores the previous token" "${BEFORE_RELOAD_FAIL}" "$(cat "${TOKEN_FILE}")"
check_contains "failed reload re-renders the proxy with the old token" "render-ollama-proxy.sh" "$(harness_stub_calls render-ollama-proxy.sh)"

# 12. Live verification sends both tokens via curl's stdin config, never argv
VERIFY_BIN="${TMP_DIR}/verify-bin"
mkdir -p "${VERIFY_BIN}"
cat > "${VERIFY_BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
# Records argv and stdin; answers 200 for the token now in the file, else 401.
printf 'ARGV %s\n' "$*" >> "${VERIFY_LOG:?}"
stdin=""
[[ " $* " == *" -K - "* ]] && stdin="$(cat)"
printf 'STDIN %s\n' "${stdin}" >> "${VERIFY_LOG}"
current="$(awk '{print $2}' "${VERIFY_TOKEN_FILE:?}")"
[[ "${stdin}" == *"Bearer ${current}"* ]] && printf 200 || printf 401
FAKE
chmod +x "${VERIFY_BIN}/curl"
export VERIFY_LOG="${TMP_DIR}/verify.log" VERIFY_TOKEN_FILE="${TOKEN_FILE}"
: > "${VERIFY_LOG}"
OLD_TOKEN="$(awk '{print $2}' "${TOKEN_FILE}")"
rc=0
OUT_VERIFY=$(PATH="${VERIFY_BIN}:${PATH}" HARNESS_STUB_SYSTEMCTL_ACTIVE=0 \
    "${KIMO}" rotate-token --file "${TOKEN_FILE}" --domain "test.internal" --reload --verify -y 2>&1) || rc=$?
NEW_TOKEN="$(awk '{print $2}' "${TOKEN_FILE}")"
check "verified rotation succeeds" "0" "${rc}"
check_contains "verification reports both probes" "new: HTTP 200, old: HTTP 401" "${OUT_VERIFY}"
check_not_contains "new token never appears in curl argv" "${NEW_TOKEN}" "$(grep '^ARGV' "${VERIFY_LOG}")"
check_not_contains "old token never appears in curl argv" "${OLD_TOKEN}" "$(grep '^ARGV' "${VERIFY_LOG}")"
check_contains "new token reaches curl via stdin" "Bearer ${NEW_TOKEN}" "$(grep '^STDIN' "${VERIFY_LOG}")"

echo ""
harness_summary "Summary"
