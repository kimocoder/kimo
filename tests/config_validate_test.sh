#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---------- config_validate_test.sh ----------
# Tests for the `kimo config validate` subcommand.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
export PATH="${ROOT_DIR}:${PATH}"
export KIMO_NO_AUTOSCAN=1

make_cfg() {
    local cfg
    cfg=$(mktemp)
    printf '%s\n' "$@" > "$cfg"
    echo "$cfg"
}

# 1) Config with only known keys => success
cfg1=$(make_cfg 'default_host=remote' 'default_model=kalidroid-27b:latest' 'kimi_effort=high')
rc=0
KIMO_CONFIG_FILE="$cfg1" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "config with only known keys validates successfully" "0" "$rc"
rm -f "$cfg1"

# 2) Config with an unknown key => failure
cfg2=$(make_cfg 'default_host=remote' 'unknown_key=bar')
rc=0
KIMO_CONFIG_FILE="$cfg2" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "unknown key detected, exit 1" "1" "$rc"
rm -f "$cfg2"

# 3) Empty config file => failure
cfg3=$(mktemp)   # empty file
rc=0
KIMO_CONFIG_FILE="$cfg3" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "empty config file detected, exit 1" "1" "$rc"
rm -f "$cfg3"

# 4) Non-existent config file => failure
nonexistent="/tmp/nonexistent-kimo-cfg-$RANDOM"
rc=0
KIMO_CONFIG_FILE="$nonexistent" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "missing config file detected, exit 1" "1" "$rc"

# 5) Config with invalid value => failure
cfg5=$(make_cfg 'kimi_effort=invalid_level')
rc=0
KIMO_CONFIG_FILE="$cfg5" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "invalid value detected, exit 1" "1" "$rc"
rm -f "$cfg5"

# 6) Config with a mixture of known and unknown => failure (unknown key reported)
cfg4=$(make_cfg 'default_host=remote' 'unknown_key=baz' 'kimi_effort=medium')
rc=0
KIMO_CONFIG_FILE="$cfg4" "${KIMO}" config validate >/dev/null 2>&1 || rc=$?
assert_eq "mixture of known/unknown keys detected, exit 1" "1" "$rc"
rm -f "$cfg4"

# 7) Structured JSON output (--json)
cfg7=$(make_cfg 'default_host=remote' 'default_model=kalidroid-27b:latest')
JSON_OUT=$(KIMO_CONFIG_FILE="$cfg7" "${KIMO}" config validate --json)
JSON_VALID=$(python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print("true" if d.get("valid") is True else "false")' "${JSON_OUT}" 2>/dev/null || echo "false")
assert_eq "JSON validation output returns valid=true" "true" "${JSON_VALID}"
rm -f "$cfg7"

# 8) Config set accepts webbridge keys without warning
cfg8=$(mktemp)
SET_OUT=$(KIMO_CONFIG_FILE="$cfg8" "${KIMO}" config set webbridge_port 10086 2>&1)
HAS_WARN=0
[[ "${SET_OUT}" == *"Warning"* ]] && HAS_WARN=1
assert_eq "config set webbridge_port emits no warning" "0" "${HAS_WARN}"

SET_OUT2=$(KIMO_CONFIG_FILE="$cfg8" "${KIMO}" config set web_engine duckduckgo 2>&1)
HAS_WARN2=0
[[ "${SET_OUT2}" == *"Warning"* ]] && HAS_WARN2=1
assert_eq "config set web_engine emits no warning" "0" "${HAS_WARN2}"

# 9) Config set rejects invalid values
rc=0
KIMO_CONFIG_FILE="$cfg8" "${KIMO}" config set webbridge_port 99999 >/dev/null 2>&1 || rc=$?
assert_eq "config set rejects out-of-range port" "1" "${rc}"

rc=0
KIMO_CONFIG_FILE="$cfg8" "${KIMO}" config set kimi_effort invalid >/dev/null 2>&1 || rc=$?
assert_eq "config set rejects invalid effort" "1" "${rc}"
rm -f "$cfg8"

# 10) Tab completions: validate and path present, preferred_cli absent
BASH_COMP=$("${KIMO}" completion bash)
HAS_VALIDATE=0
[[ "${BASH_COMP}" == *"validate"* ]] && HAS_VALIDATE=1
assert_eq "Bash completion contains validate" "1" "${HAS_VALIDATE}"

HAS_PATH=0
[[ "${BASH_COMP}" == *"path"* ]] && HAS_PATH=1
assert_eq "Bash completion contains path" "1" "${HAS_PATH}"

HAS_PREFERRED_CLI=0
[[ "${BASH_COMP}" == *"preferred_cli"* ]] && HAS_PREFERRED_CLI=1
assert_eq "Bash completion does not contain preferred_cli" "0" "${HAS_PREFERRED_CLI}"

echo "=== config_validate_test.sh completed (${pass} passed, ${fail} failed) ==="
[[ "${fail}" -eq 0 ]] || exit 1