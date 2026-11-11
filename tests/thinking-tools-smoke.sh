#!/usr/bin/env bash
# Headless checks for the shared model-spec capability mapping.
#
# Ollama capabilities map thinking->thinking, tools->tool_use and
# vision->image_in. Thinking models get support_efforts/off_effort/
# reasoning_key/default effort; explicit overrides win over probed values.
# Kimi's launch integration now lives in kimi-smoke.sh because Kimi uses
# Kalidroid rather than Ollama/vLLM.

set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
TMPDIR_T="$(mktemp -d)"
SPEC_SRC="${TMPDIR_T}/spec.sh"
awk '/^_kimi_model_spec\(\)/,/^}/' "${KIMO}" > "${SPEC_SRC}"
grep -q '_kimi_model_spec()' "${SPEC_SRC}" || { echo "FATAL: could not extract _kimi_model_spec"; exit 1; }

STUB_BIN="${TMPDIR_T}/stubbin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
url="" body=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) body="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[[ "${url}" == */api/show ]] || { printf '{}'; exit 0; }
case "${body}" in
    *thinker*)  printf '%s' '{"capabilities":["thinking","tools"],"parameters":"num_ctx 8192","model_info":{"llama.context_length":131072}}' ;;
    *plain*)    printf '%s' '{"capabilities":["tools"],"parameters":"num_ctx 4096","model_info":{"llama.context_length":32768}}' ;;
    *visionary*) printf '%s' '{"capabilities":["vision","tools"],"model_info":{"llama.context_length":8192}}' ;;
    *)          exit 1 ;;
esac
STUB
chmod +x "${STUB_BIN}/curl"

spec_for() {
    local model="$1"; shift
    PATH="${STUB_BIN}:/usr/bin:/bin" bash -c '
        source "$1"; shift
        _kimi_model_spec "http://127.0.0.1:9" "ollama-test" "$@"
    ' _ "${SPEC_SRC}" "${model}" "$@"
}
jqv() { jq -r ".$2" <<<"$1"; }

spec="$(spec_for thinker:latest)"
check "thinking maps to thinking" "thinking,tool_use" "$(jqv "${spec}" caps)"
check "thinking sets efforts" "low,medium,high,xhigh,max" "$(jqv "${spec}" efforts)"
check "thinking sets off_effort" "none" "$(jqv "${spec}" off)"
check "thinking sets reasoning_key" "reasoning" "$(jqv "${spec}" rkey)"
check "thinking sets default effort" "high" "$(jqv "${spec}" deff)"
check "runtime num_ctx wins over arch max" "8192" "$(jqv "${spec}" ctx)"

spec="$(spec_for plain:latest)"
check "tools-only maps to tool_use" "tool_use" "$(jqv "${spec}" caps)"
check "non-thinking has no efforts" "" "$(jqv "${spec}" efforts)"
check "non-thinking has no off_effort" "" "$(jqv "${spec}" off)"
check "non-thinking has no reasoning_key" "" "$(jqv "${spec}" rkey)"
check "non-thinking has no default effort" "" "$(jqv "${spec}" deff)"

spec="$(spec_for visionary:latest)"
check "vision maps to image_in" "image_in,tool_use" "$(jqv "${spec}" caps)"
check "arch max used when no runtime num_ctx" "8192" "$(jqv "${spec}" ctx)"
spec="$(spec_for unknown:latest)"
check "failed probe falls back to tool_use" "tool_use" "$(jqv "${spec}" caps)"
check "failed probe yields no thinking fields" "" "$(jqv "${spec}" rkey)"

spec="$(spec_for plain:latest "" "thinking,tool_use")"
check "cap override beats probe" "thinking,tool_use" "$(jqv "${spec}" caps)"
check "cap override enables thinking fields" "reasoning" "$(jqv "${spec}" rkey)"
spec="$(spec_for thinker:latest "" "" "low,high" "xhigh" "off" "reasoning_content")"
check "efforts override" "low,high" "$(jqv "${spec}" efforts)"
check "default effort override" "xhigh" "$(jqv "${spec}" deff)"
check "off effort override" "off" "$(jqv "${spec}" off)"
check "reasoning_key override" "reasoning_content" "$(jqv "${spec}" rkey)"
spec="$(spec_for thinker:latest "2048")"
check "ctx override beats runtime num_ctx" "2048" "$(jqv "${spec}" ctx)"

echo
echo "thinking/tools checks: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
