#!/usr/bin/env bash
# Tests for Claude and Gemini token inspection, export, auto-renewal and launch routing.
#
# Usage: tests/token_providers_test.sh

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

TMP_DIR="$(mktemp -d "${HARNESS_ROOT}/token_test.XXXXXX")"
CLAUDE_HOME="${TMP_DIR}/claude_home"
GEMINI_HOME="${TMP_DIR}/gemini_home"
GROK_HOME="${TMP_DIR}/grok_home"
KIMI_HOME="${TMP_DIR}/kimi_home"
mkdir -p "${CLAUDE_HOME}" "${GEMINI_HOME}/antigravity-cli" "${GROK_HOME}" "${KIMI_HOME}/.kimi-code"

MOCK_CLAUDE_ACCESS="sk-ant-oat01-test-token-1234567890"
MOCK_CLAUDE_REFRESH="mock-claude-refresh-token"
MOCK_GEMINI_ACCESS="ya29.a0AehfTO-mock-gemini-token"
MOCK_GEMINI_REFRESH="mock-gemini-refresh-token"
MOCK_GROK_ACCESS="eyJ0eXAiOiJhdCtqd3QiLCJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEyMyIsImVtYWlsIjoidGVzdEBleGFtcGxlLmNvbSIsImV4cCI6MTg5MzQ1NjAwMH0.mock-sig"

# Future expiration timestamp (1 hour from now)
FUTURE_EXP_MS=$(( ($(date +%s) + 3600) * 1000 ))
FUTURE_EXP_ISO="$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0) + datetime.timedelta(hours=1))")"

cat > "${CLAUDE_HOME}/.credentials.json" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "${MOCK_CLAUDE_ACCESS}",
    "refreshToken": "${MOCK_CLAUDE_REFRESH}",
    "expiresAt": ${FUTURE_EXP_MS},
    "subscriptionType": "pro",
    "rateLimitTier": "default_claude_ai"
  }
}
EOF

cat > "${GEMINI_HOME}/antigravity-cli/antigravity-oauth-token" <<EOF
{
  "token": {
    "access_token": "${MOCK_GEMINI_ACCESS}",
    "refresh_token": "${MOCK_GEMINI_REFRESH}",
    "token_type": "Bearer",
    "expiry": "${FUTURE_EXP_ISO}"
  },
  "id_token_email": "test-user@example.com",
  "auth_method": "consumer"
}
EOF

cat > "${GROK_HOME}/auth.json" <<EOF
{
  "https://auth.x.ai::mock": {
    "key": "${MOCK_GROK_ACCESS}",
    "auth_mode": "oidc",
    "email": "test-grok@example.com",
    "team_id": "team-mock-42",
    "expires_at": "${FUTURE_EXP_ISO}"
  }
}
EOF

printf 'default_model = "unrelated/model"\n' > "${KIMI_HOME}/.kimi-code/config.toml"

echo "[*] [1] kimo claude token, status and export"
export CLAUDE_CONFIG_DIR="${CLAUDE_HOME}"
export KIMI_CONFIG="${KIMI_HOME}/.kimi-code/config.toml"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY

status_out=$("${KIMO}" claude status)
check_contains "claude status finds credentials" "Found" "${status_out}"
check_contains "claude status reports active token" "Active" "${status_out}"
check_contains "claude status reports plan" "pro (default_claude_ai)" "${status_out}"

token_out=$("${KIMO}" claude --token)
check "claude --token prints exact access token" "${MOCK_CLAUDE_ACCESS}" "${token_out}"

token_json=$("${KIMO}" claude --token --json)
check_contains "claude --token --json output has token" "${MOCK_CLAUDE_ACCESS}" "${token_json}"

export_out=$("${KIMO}" claude --export)
check_contains "claude --export exports CLAUDE_CODE_OAUTH_TOKEN" "export CLAUDE_CODE_OAUTH_TOKEN=${MOCK_CLAUDE_ACCESS}" "${export_out}"
check_contains "claude --export exports ANTHROPIC_AUTH_TOKEN" "export ANTHROPIC_AUTH_TOKEN=${MOCK_CLAUDE_ACCESS}" "${export_out}"

json_out=$("${KIMO}" claude --json)
check_contains "claude --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "claude --json reports subscription" '"subscription_type": "pro"' "${json_out}"

sync_out=$("${KIMO}" claude sync)
check_contains "claude sync configures provider" "Synchronized" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote anthropic provider" "[providers.anthropic]" "${cfg_content}"
check_contains "sync registered claude opus" 'claude-opus-5-5' "${cfg_content}"

echo "[*] [2] kimo gemini token, status and export"
export GEMINI_HOME="${GEMINI_HOME}"
unset GEMINI_AUTH_TOKEN GOOGLE_OAUTH_TOKEN GEMINI_API_KEY GOOGLE_API_KEY

status_out=$("${KIMO}" gemini status)
check_contains "gemini status finds credentials" "Found" "${status_out}"
check_contains "gemini status reports account" "test-user@example.com" "${status_out}"
check_contains "gemini status reports active token" "Active" "${status_out}"

token_out=$("${KIMO}" gemini --token)
check "gemini --token prints exact access token" "${MOCK_GEMINI_ACCESS}" "${token_out}"

token_json=$("${KIMO}" gemini --token --json)
check_contains "gemini --token --json output has token" "${MOCK_GEMINI_ACCESS}" "${token_json}"

export_out=$("${KIMO}" gemini --export)
check_contains "gemini --export exports GEMINI_AUTH_TOKEN" "export GEMINI_AUTH_TOKEN=${MOCK_GEMINI_ACCESS}" "${export_out}"

json_out=$("${KIMO}" gemini --json)
check_contains "gemini --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "gemini --json reports email" '"email": "test-user@example.com"' "${json_out}"

sync_out=$("${KIMO}" gemini sync 2>&1)
check_contains "gemini sync configures provider" "wrote" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote gemini provider" "[providers.gemini]" "${cfg_content}"
check_contains "sync wrote api_key_env for oauth" 'api_key_env = "GEMINI_AUTH_TOKEN"' "${cfg_content}"
check_contains "sync registered gemini flash" 'gemini-2.5-flash' "${cfg_content}"

quota_out=$("${KIMO}" quota --provider gemini)
check_contains "quota reports gemini online" "Gemini: online" "${quota_out}"
check_contains "quota reports model count" "matching models" "${quota_out}"

echo "[*] [3] kimo grok token, status and export"
export GROK_HOME="${GROK_HOME}"
unset XAI_AUTH_TOKEN XAI_API_KEY GROK_AUTH_TOKEN

status_out=$("${KIMO}" grok status)
check_contains "grok status finds credentials" "Found" "${status_out}"
check_contains "grok status reports account" "test-grok@example.com" "${status_out}"
check_contains "grok status reports active token" "Active" "${status_out}"

token_out=$("${KIMO}" grok --token)
check "grok --token prints exact access token" "${MOCK_GROK_ACCESS}" "${token_out}"

token_json=$("${KIMO}" grok --token --json)
check_contains "grok --token --json output has token" "${MOCK_GROK_ACCESS}" "${token_json}"

export_out=$("${KIMO}" grok --export)
check_contains "grok --export exports XAI_AUTH_TOKEN" "export XAI_AUTH_TOKEN=${MOCK_GROK_ACCESS}" "${export_out}"

json_out=$("${KIMO}" grok --json)
check_contains "grok --json reports valid token" '"token_valid": true' "${json_out}"
check_contains "grok --json reports email" '"email": "test-grok@example.com"' "${json_out}"

sync_out=$("${KIMO}" grok sync 2>&1)
check_contains "grok sync configures provider" "Synchronized" "${sync_out}"
cfg_content=$(cat "${KIMI_CONFIG}")
check_contains "sync wrote xai provider" "[providers.xai]" "${cfg_content}"
check_contains "sync wrote api_key_env for oauth" 'api_key_env = "XAI_AUTH_TOKEN"' "${cfg_content}"
check_contains "sync registered grok 4.7" 'grok-4.7' "${cfg_content}"

echo "[*] [4] Launch codex provider auto-resolution with OAuth tokens"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
    GEMINI_API_KEY GEMINI_AUTH_TOKEN GOOGLE_API_KEY GOOGLE_OAUTH_TOKEN \
    XAI_API_KEY XAI_AUTH_TOKEN GROK_AUTH_TOKEN

dry_claude=$("${KIMO}" launch codex --provider claude --dry-run)
check_contains "launch claude uses CLAUDE_CODE_OAUTH_TOKEN env_key" 'env_key=\"CLAUDE_CODE_OAUTH_TOKEN\"' "${dry_claude}"
check_contains "launch claude masks oauth secret" 'CLAUDE_CODE_OAUTH_TOKEN <kept: real value, Anthropic key>' "${dry_claude}"
check_not_contains "dry-run never exposes raw token" "${MOCK_CLAUDE_ACCESS}" "${dry_claude}"

dry_gemini=$("${KIMO}" launch codex --provider gemini --dry-run)
check_contains "launch gemini uses GEMINI_AUTH_TOKEN env_key" 'env_key=\"GEMINI_AUTH_TOKEN\"' "${dry_gemini}"
check_contains "launch gemini masks oauth secret" 'GEMINI_AUTH_TOKEN <kept: real value, Gemini key>' "${dry_gemini}"
check_not_contains "dry-run never exposes raw token" "${MOCK_GEMINI_ACCESS}" "${dry_gemini}"

dry_xai=$("${KIMO}" launch codex --provider xai --dry-run)
check_contains "launch xai uses XAI_AUTH_TOKEN env_key" 'env_key=\"XAI_AUTH_TOKEN\"' "${dry_xai}"
check_contains "launch xai masks oauth secret" 'XAI_AUTH_TOKEN <kept: real value, xAI key>' "${dry_xai}"
check_not_contains "dry-run never exposes raw token" "${MOCK_GROK_ACCESS}" "${dry_xai}"

echo
harness_summary "token_providers"
