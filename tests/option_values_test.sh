#!/usr/bin/env bash
# A value-taking option given last must fail with "<opt> requires a value",
# never exit silently (a bare 'shift 2' under set -e) or hang.
#
# Usage: tests/option_values_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    read -r -a argv <<<"${line}"
    flag="${argv[-1]}"
    rc=0
    out=$(timeout 10 "${KIMO}" "${argv[@]}" </dev/null 2>&1) || rc=$?
    check "kimo ${line}: exits 1" "1" "${rc}"
    check_contains "kimo ${line}: names the flag" "${flag} requires a value" "${out}"
done <<'EOF'
bench model -p
bench model -n
bench model --temp
scan -p
scan --threads
scan --timeout
scan --set-remote
sync model --from
sync model --to
tunnel logs -n
web search --results --wait
rotate-token --file
EOF

harness_summary "option values"
