#!/usr/bin/env bash
# Host address normalization (--host, sync --from/--to, OLLAMA_LOCAL_URL):
# Ollama's :11434 is only added to a bare http host; https:// and proxied
# paths keep their own port, and a port never lands after the path.
#
# Usage: tests/host_url_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

FN="$(mktemp)"
awk '/^normalize_host_url\(\) \{/,/^}/' "${KIMO}" > "${FN}"
# shellcheck source=/dev/null
source "${FN}"
declare -F normalize_host_url >/dev/null || { bad "could not extract normalize_host_url"; exit 1; }

while IFS='|' read -r input expected; do
    [[ -z "${input}" ]] && continue
    check "${input}" "${expected}" "$(normalize_host_url "${input}")"
done <<'EOF'
192.168.1.5|http://192.168.1.5:11434
192.168.1.5:8080|http://192.168.1.5:8080
gpu.lan/|http://gpu.lan:11434
http://gpu.lan|http://gpu.lan:11434
http://gpu.lan:11434/|http://gpu.lan:11434
HTTP://gpu.lan:9000|http://gpu.lan:9000
https://example.com|https://example.com
https://example.com:8443|https://example.com:8443
https://example.invalid/ollama|https://example.invalid/ollama
http://example.invalid/ollama/|http://example.invalid/ollama
example.invalid/ollama|http://example.invalid/ollama
http://gpu.lan:8080/ollama|http://gpu.lan:8080/ollama
[::1]|http://[::1]:11434
[::1]:11500|http://[::1]:11500
http://[fe80::1]|http://[fe80::1]:11434
http://user:pw@gpu.lan|http://user:pw@gpu.lan:11434
http://user:pw@gpu.lan:9|http://user:pw@gpu.lan:9
EOF

# End to end: --host goes through the same normalization.
url=$("${KIMO}" --host "https://example.invalid/ollama" check --json 2>/dev/null | jq -r '.[0].url' 2>/dev/null || true)
check "--host keeps a proxied https path intact" "https://example.invalid/ollama" "${url}"

harness_summary "host url"
