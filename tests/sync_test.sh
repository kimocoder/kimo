#!/usr/bin/env bash
# kimo sync: a model on a local source is replicated by copying its blobs
# (POST /api/blobs + /api/create) and verified by the weights the destination
# reports; a registry-pull fallback must match the source digest or fail.
#
# Usage: tests/sync_test.sh
set -euo pipefail
# shellcheck source=lib/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIMO="${ROOT_DIR}/kimo"

# A model store in Ollama's on-disk layout: blobs/sha256-<hex> plus a manifest
# under manifests/registry.ollama.ai/library/<model>/<tag>.
STORE="${KIMO_OLLAMA_MODELS}"
SOURCE_DIGEST="$(python3 - "${STORE}" <<'PY'
import hashlib, json, os, sys
store = sys.argv[1]
os.makedirs(f"{store}/blobs", exist_ok=True)
def blob(data, media):
    digest = "sha256:" + hashlib.sha256(data).hexdigest()
    with open(f"{store}/blobs/{digest.replace(':', '-')}", "wb") as fh:
        fh.write(data)
    return {"mediaType": f"application/vnd.ollama.image.{media}", "digest": digest, "size": len(data)}
manifest = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
    "config": {"mediaType": "application/vnd.docker.container.image.v1+json",
               "digest": "sha256:" + "c" * 64, "size": 2},
    "layers": [blob(b"GGUF" + os.urandom(4096), "model"),
               blob(b"{{ .Prompt }}", "template"),
               blob(json.dumps({"temperature": 0.2, "stop": ["<|end|>"]}).encode(), "params")],
}
raw = json.dumps(manifest).encode()
path = f"{store}/manifests/registry.ollama.ai/library/fixture-model/latest"
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "wb") as fh:
    fh.write(raw)
print("sha256:" + hashlib.sha256(raw).hexdigest())
PY
)"
MODEL_BLOB="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print([l["digest"] for l in m["layers"] if l["mediaType"].endswith(".model")][0])' \
    "${STORE}/manifests/registry.ollama.ai/library/fixture-model/latest")"

harness_fake_ollama --models "fixture-model:latest@${SOURCE_DIGEST}"
SRC_URL="${FAKE_OLLAMA_URL}"
harness_fake_ollama --models ""
DST_URL="${FAKE_OLLAMA_URL}" DST_LOG="${FAKE_OLLAMA_LOG}"

echo "[*] local source: blobs are copied, not pulled from a registry"
rc=0
out=$("${KIMO}" sync fixture-model --from "${SRC_URL}" --to "${DST_URL}" 2>&1) || rc=$?
check "sync exits 0" "0" "${rc}"
check_contains "weights are reported as verified" "weights verified (${MODEL_BLOB:7:12})" "${out}"
check_contains "the weight blob was uploaded" "POST /api/blobs/${MODEL_BLOB}" "$(cat "${DST_LOG}")"
check_not_contains "the destination never pulled from a registry" "/api/pull" "$(cat "${DST_LOG}")"
create_line="$(grep '^POST /api/create ' "${DST_LOG}" || true)"
check_contains "create references the copied weights" "\"${MODEL_BLOB}\"" "${create_line}"
check_contains "create carries the template layer" '"template":"{{ .Prompt }}"' "${create_line}"
check_contains "create carries the params layer" '"stop":["<|end|>"]' "${create_line}"

echo "[*] re-running recognizes identical weights"
uploads_before=$(grep -c '^POST /api/blobs/' "${DST_LOG}" || true)
rc=0
out=$("${KIMO}" sync fixture-model --from "${SRC_URL}" --to "${DST_URL}" 2>&1) || rc=$?
check "second sync exits 0" "0" "${rc}"
check_contains "second sync reports identical weights" "already has identical weights" "${out}"
check "second sync uploads nothing" "${uploads_before}" "$(grep -c '^POST /api/blobs/' "${DST_LOG}" || true)"

echo "[*] different weights on the destination need --force"
harness_fake_ollama --models "fixture-model:latest@sha256:$(printf 'd%.0s' {1..64})"
OTHER_URL="${FAKE_OLLAMA_URL}"
rc=0
out=$("${KIMO}" sync fixture-model --from "${SRC_URL}" --to "${OTHER_URL}" 2>&1) || rc=$?
check "differing destination is refused without --force" "1" "${rc}"
check_contains "refusal explains --force" "different weights; re-run with --force" "${out}"
rc=0
out=$("${KIMO}" sync fixture-model --from "${SRC_URL}" --to "${OTHER_URL}" --force 2>&1) || rc=$?
check "--force overwrites and verifies" "0" "${rc}"
check_contains "--force result is verified" "weights verified" "${out}"

echo "[*] no readable store: registry pull must match the source digest"
harness_fake_ollama --models ""
PULL_URL="${FAKE_OLLAMA_URL}" PULL_LOG="${FAKE_OLLAMA_LOG}"
rc=0
out=$(KIMO_OLLAMA_MODELS="${HARNESS_ROOT}/empty-store" "${KIMO}" sync fixture-model --from "${SRC_URL}" --to "${PULL_URL}" 2>&1) || rc=$?
check_contains "fallback is announced" "falling back to a registry pull" "${out}"
check_contains "the destination was asked to pull" "POST /api/pull" "$(cat "${PULL_LOG}")"
check "an unverifiable registry copy fails" "1" "${rc}"
check_contains "the mismatch is explained" "does not match" "${out}"
check_not_contains "no false success is printed" "Synchronized 'fixture-model'" "${out}"

echo
harness_summary "sync"
