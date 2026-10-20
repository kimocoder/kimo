#!/usr/bin/env python3
"""Minimal loopback Ollama stand-in for hermetic kimo tests.

Serves the read endpoints kimo probes (/, /api/version, /api/tags, /api/ps,
/api/show) and canned write endpoints (/api/pull streams NDJSON events,
/api/generate, /api/chat, /api/copy, /api/delete, /api/blobs/<digest>,
/api/create). Every request is appended to --log as "METHOD /path", followed
by the compact JSON body for JSON requests, so tests can assert which daemon
kimo talked to and what it asked for.

Blobs uploaded with POST /api/blobs/<digest> are digest-checked like the real
server and stored under --blob-dir; /api/create registers the model in
/api/tags, so a sync can be verified end to end.

Started by harness_fake_ollama in tests/lib/harness.sh; the bound port is
written to --port-file once the socket is listening.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PULL = [
    {"status": "pulling manifest"},
    {"status": "pulling fixture", "digest": "sha256:fixture", "total": 4, "completed": 2},
    {"status": "pulling fixture", "digest": "sha256:fixture", "total": 4, "completed": 4},
    {"status": "verifying sha256 digest"},
    {"status": "writing manifest"},
    {"status": "success"},
]


def parse_models(spec: str) -> dict[str, str]:
    """'a:latest,b:1b@sha256:<hex>' -> {name: hex digest}.

    Like the real server, /api/tags reports manifest digests as bare hex.
    """
    models = {}
    for index, item in enumerate(filter(None, spec.split(",")), start=1):
        name, _, digest = item.partition("@")
        models[name] = digest.removeprefix("sha256:") or f"{index:064x}"
    return models


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        pass

    def _record(self, body: object = None) -> None:
        line = f"{self.command} {self.path}"
        if body:
            line += " " + json.dumps(body, sort_keys=True, separators=(",", ":"))
        with self.server.lock, open(self.server.log_path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    def _raw_body(self) -> bytes:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        return self.rfile.read(length) if length > 0 else b""

    def _send(self, status: int, data: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _json(self, status: int, payload: object) -> None:
        self._send(status, json.dumps(payload).encode(), "application/json")

    def _blob_path(self, digest: str) -> str | None:
        """Blob file for a well-formed sha256 digest; None for anything else."""
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            return None
        root = os.path.realpath(self.server.blob_dir)
        path = os.path.realpath(os.path.join(root, digest.replace(":", "-")))
        return path if path.startswith(root + os.sep) else None

    def _has_blob(self, digest: str) -> bool:
        path = self._blob_path(digest)
        return path is not None and os.path.exists(path)

    def do_HEAD(self) -> None:
        self._record()
        if self.path.startswith("/api/blobs/"):
            digest = self.path.rsplit("/", 1)[1]
            self._send(200 if self._has_blob(digest) else 404, b"", "text/plain")
        else:
            self._send(200, b"", "text/plain")

    def do_GET(self) -> None:
        self._record()
        with self.server.lock:
            models = [
                {"name": name, "model": name, "digest": digest, "size": 1024,
                 "details": {"family": "fixture", "parameter_size": "1B", "format": "gguf",
                             "quantization_level": "Q4_0"}}
                for name, digest in self.server.models.items()
            ]
        if self.path == "/":
            self._send(200, b"Ollama is running", "text/plain")
        elif self.path == "/api/version":
            self._json(200, {"version": "0.0.0-fixture"})
        elif self.path == "/api/tags":
            self._json(200, {"models": models})
        elif self.path == "/api/ps":
            self._json(200, {"models": [{"name": name, "model": name} for name in self.server.loaded]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        raw = self._raw_body()
        if self.path.startswith("/api/blobs/"):
            self._record()
            digest = self.path.rsplit("/", 1)[1]
            path = self._blob_path(digest)
            if path is None or "sha256:" + hashlib.sha256(raw).hexdigest() != digest:
                self._json(400, {"error": "digest mismatch"})
                return
            with open(path, "wb") as fh:
                fh.write(raw)
            self._send(201, b"", "text/plain")
            return
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        self._record(body)
        if self.path == "/api/pull":
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            for event in self.server.pull_events:
                self.wfile.write((json.dumps(event) + "\n").encode())
                self.wfile.flush()
            self.close_connection = True
        elif self.path == "/api/show":
            name = body.get("model") or body.get("name") or ""
            name = name if ":" in name.split("/")[-1] else name + ":latest"
            with self.server.lock:
                known = name in self.server.models
                created = self.server.created.get(name)
            if not known:
                self._json(404, {"error": f"model '{name}' not found"})
                return
            # Like the real server, the modelfile names the weight blobs it uses.
            if created:
                lines = [f"FROM /blobs/{d.replace(':', '-')}" for d in (created.get("files") or {}).values()]
                lines += [f"ADAPTER /blobs/{d.replace(':', '-')}" for d in (created.get("adapters") or {}).values()]
            else:
                lines = [f"FROM /blobs/sha256-{hashlib.sha256(name.encode()).hexdigest()}"]
            self._json(200, {"capabilities": ["completion"], "parameters": "",
                             "template": "", "system": "", "modelfile": "\n".join(lines) + "\n",
                             "details": {"family": "fixture", "parameter_size": "1B", "format": "gguf",
                                         "quantization_level": "Q4_0"},
                             "model_info": {"fixture.context_length": 8192}})
        elif self.path == "/api/create":
            name = body.get("model") or body.get("name") or ""
            missing = [d for d in list((body.get("files") or {}).values())
                       + list((body.get("adapters") or {}).values())
                       if not self._has_blob(d)]
            if not name or missing:
                self._json(400, {"error": f"missing blobs: {missing}" if missing else "model name required"})
                return
            digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
            name = name if ":" in name.split("/")[-1] else name + ":latest"
            with self.server.lock:
                self.server.models[name] = digest
                self.server.created[name] = body
            self._json(200, {"status": "success"})
        elif self.path == "/api/generate" and body.get("stream") is True:
            self._stream_generate(body)
        elif self.path in ("/api/generate", "/api/chat"):
            self._json(200, {"model": body.get("model", ""), "done": True, "response": ""})
        elif self.path in ("/api/copy", "/api/delete"):
            self._json(200, {})
        else:
            self._json(404, {"error": "not found"})

    def _stream_generate(self, body: dict) -> None:
        """NDJSON like the real server: the first request for a model pays a
        0.5s cold load, and every reply waits 0.1s before its first token."""
        model = body.get("model", "")
        with self.server.lock:
            cold = model not in self.server.warm
            self.server.warm.add(model)
        tokens = int((body.get("options") or {}).get("num_predict") or 3)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        time.sleep(0.6 if cold else 0.1)
        for _ in range(tokens):
            self.wfile.write(json.dumps({"model": model, "response": "x", "done": False}).encode() + b"\n")
        self.wfile.write(json.dumps({
            "model": model, "response": "", "done": True,
            "load_duration": 500_000_000 if cold else 0,
            "prompt_eval_count": len(str(body.get("prompt", "")).split()),
            "prompt_eval_duration": 20_000_000,
            "eval_count": tokens, "eval_duration": 50_000_000,
        }).encode() + b"\n")

    def do_DELETE(self) -> None:
        self.do_POST()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--models", default="fixture-model:latest",
                        help="comma-separated tags served by /api/tags, each optionally name@sha256:<hex>")
    parser.add_argument("--loaded", default="", help="comma-separated tags reported by /api/ps")
    parser.add_argument("--pull-events",
                        help="file of NDJSON events streamed by /api/pull (default: a success sequence)")
    parser.add_argument("--blob-dir", help="where uploaded blobs are kept (default: next to --log)")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.log_path = args.log
    server.lock = threading.Lock()
    server.models = parse_models(args.models)
    server.created = {}
    server.warm = set()
    server.loaded = [name for name in args.loaded.split(",") if name]
    server.blob_dir = args.blob_dir or args.log + ".blobs"
    os.makedirs(server.blob_dir, exist_ok=True)
    if args.pull_events:
        with open(args.pull_events, encoding="utf-8") as fh:
            server.pull_events = [json.loads(line) for line in fh if line.strip()]
    else:
        server.pull_events = DEFAULT_PULL

    def stop(signum: int, frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    with open(args.port_file, "w", encoding="utf-8") as fh:
        fh.write(f"{server.server_address[1]}\n")
    try:
        server.serve_forever()
    finally:
        server.server_close()
    sys.exit(0)


if __name__ == "__main__":
    main()
