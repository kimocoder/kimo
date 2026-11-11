#!/usr/bin/env bash
# vLLM is no longer a Kimi launch backend; Kalidroid replaces it.

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

rc=0
out=$("${KIMO}" launch kimi --provider vllm --dry-run 2>&1) || rc=$?
check "Kimi rejects the removed vLLM provider" 1 "${rc}"
check_contains "the rejection names Kalidroid as the replacement" "kalidroid" "${out}"
check_not_contains "vLLM rejection never starts an Ollama fallback" "ollama run" "${out}"

rc=0
out=$("${KIMO}" launch kimi --model vllm/org/model --dry-run 2>&1) || rc=$?
check "Kimi rejects a vllm/ model alias" 1 "${rc}"
check_contains "the alias rejection names Kalidroid" "kalidroid" "${out}"

harness_summary "vllm_removed_from_kimi"
