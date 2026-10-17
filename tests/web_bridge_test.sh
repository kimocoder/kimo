#!/usr/bin/env bash
# kimo web against fake WebBridge daemons:
#   * only an HTTP 2xx without an error body counts as dispatched; HTTP errors
#     and {"ok": false} / {"error": ...} replies exit 1 with the reason
#   * printed manual commands stay valid shell when the query contains quotes
#   * search --results extracts {title, url} pairs via the evaluate action
#
# Usage: tests/web_bridge_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"
WORK="$(mktemp -d)"

cat > "${WORK}/bridge.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, port_file, log = sys.argv[1:4]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with open(log, "a") as fh:
            fh.write(json.dumps(body) + "\n")
        if mode == "http500":
            status, reply = 500, {"error": "relay crashed"}
        elif mode == "okfalse":
            status, reply = 200, {"ok": False, "error": "no browser attached"}
        elif body.get("action") == "evaluate":
            links = [{"t": "Kimo docs", "h": "https://example.org/kimo"}, {"t": "Ollama", "h": "https://ollama.com/"}]
            status, reply = 200, {"ok": True, "result": {"value": json.dumps(links)}}
        else:
            status, reply = 200, {"ok": True, "tab": 7}
        data = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(port_file, "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PY

start_bridge() { # <mode> -> sets BRIDGE_URL, BRIDGE_LOG
    local port_file="${WORK}/$1.port" tries=0
    BRIDGE_LOG="${WORK}/$1.log"
    : > "${BRIDGE_LOG}"
    harness_spawn python3 "${WORK}/bridge.py" "$1" "${port_file}" "${BRIDGE_LOG}"
    until [[ -s "${port_file}" ]]; do
        ((tries++ < 100)) || { bad "fake bridge '$1' did not start"; exit 1; }
        sleep 0.05
    done
    BRIDGE_URL="http://127.0.0.1:$(<"${port_file}")/command"
}

echo "[*] healthy bridge"
start_bridge ok
OK_URL="${BRIDGE_URL}" OK_LOG="${BRIDGE_LOG}"
rc=0
out=$(KIMO_WEBBRIDGE_URL="${OK_URL}" "${KIMO}" web fetch https://example.org 2>&1) || rc=$?
check "fetch succeeds on HTTP 200" "0" "${rc}"
check_contains "fetch reports dispatch" "dispatched to WebBridge" "${out}"

rc=0
out=$(KIMO_WEBBRIDGE_URL="${OK_URL}" "${KIMO}" web search --results "don't panic" 2>/dev/null) || rc=$?
check "search --results succeeds" "0" "${rc}"
check_contains "search --results lists titles" "1. Kimo docs" "${out}"
check_contains "search --results lists urls" "https://ollama.com/" "${out}"
check_contains "the evaluate action was sent" '"action": "evaluate"' "$(cat "${OK_LOG}")"

json=$(KIMO_WEBBRIDGE_URL="${OK_URL}" "${KIMO}" web search --results --json "kimo" 2>/dev/null || true)
check "search --results --json returns structured results" "2" "$(jq '.results | length' <<<"${json}" 2>/dev/null || echo bad)"
check "search --results --json first url" "https://example.org/kimo" "$(jq -r '.results[0].url' <<<"${json}" 2>/dev/null || echo bad)"
json=$(KIMO_WEBBRIDGE_URL="${OK_URL}" "${KIMO}" web search --json "kimo" 2>/dev/null || true)
check "a bare search --json returns parsed links" "2" "$(jq '.results | length' <<<"${json}" 2>/dev/null || echo bad)"
json=$(KIMO_WEBBRIDGE_URL="${OK_URL}" "${KIMO}" web search --open --json "kimo" 2>/dev/null || true)
check "search --open --json only reports the dispatch" "7" "$(jq -r '.tab' <<<"${json}" 2>/dev/null || echo bad)"
check_contains "the extractor unwraps redirect links" "uddg" "$(sed -n '/^cmd_web() {/,/^}/p' "${KIMO}")"

echo "[*] failing bridges"
declare -A expect_reason=([http500]="HTTP 500" [okfalse]="no browser attached")
for mode in http500 okfalse; do
    start_bridge "${mode}"
    for sub in fetch search; do
        rc=0
        if [[ "${sub}" == fetch ]]; then
            out=$(KIMO_WEBBRIDGE_URL="${BRIDGE_URL}" "${KIMO}" web fetch https://example.org 2>&1) || rc=$?
        else
            out=$(KIMO_WEBBRIDGE_URL="${BRIDGE_URL}" "${KIMO}" web search kimo 2>&1) || rc=$?
        fi
        check "${mode}: web ${sub} exits 1" "1" "${rc}"
        check_not_contains "${mode}: web ${sub} does not claim success" "dispatched" "${out}"
        check_contains "${mode}: web ${sub} reports why" "${expect_reason[${mode}]}" "${out}"
    done
done

echo "[*] printed commands survive quotes"
manual=$("${KIMO}" web search "it's a \"test\"" 2>&1 | grep -m1 'curl -s -X POST' || true)
manual="${manual#"${manual%%curl*}"}"
check_contains "unreachable bridge prints a manual command" "curl -s -X POST" "${manual}"
# The printed command must parse as shell and hand the exact JSON to curl.
sent=$(bash -c "curl() { while [[ \$# -gt 0 ]]; do [[ \$1 == -d ]] && { printf '%s' \"\$2\"; return; }; shift; done; }; ${manual}")
check "manual command passes the query through intact" "search: it's a \"test\"" "$(jq -r '.args.group_title' <<<"${sent}" 2>/dev/null || echo unparseable)"

# Run the printed multi-line command (with its \ continuations) exactly as shown.
urlcmd=$("${KIMO}" web url "https://example.org/?q=it's" 2>/dev/null | sed '1d')
sent=$(bash -c "curl() { while [[ \$# -gt 0 ]]; do [[ \$1 == -d ]] && { printf '%s' \"\$2\"; return; }; shift; done; }; ${urlcmd}")
check "web url command keeps a quoted URL intact" "https://example.org/?q=it's" "$(jq -r '.args.url' <<<"${sent}" 2>/dev/null || echo unparseable)"

harness_summary "web bridge"
