#!/usr/bin/env python3
"""
kimo-chat-proxy.py - loopback OpenAI chat relay for Kimi Code.

Some OpenAI-compatible hosts send a reasoning model's scratchpad inline in
`content`. A Qwen3-style chat template opens the ` thinking` block in the
prompt, so the wire carries only the reasoning, a bare `` and then the
answer. Kimi Code reads reasoning from `reasoning_content` (also
`reasoning_details` and `reasoning`); it has no inline-tag parser. The trace is
therefore rendered as the answer and the turn looks like it stopped after
planning.

This proxy sits between Kimi and the upstream host and moves that text onto
`reasoning_content`, for streaming SSE and whole JSON bodies alike. Everything
else - tool calls, usage, finish reasons, errors - passes through untouched.
The credential is the caller's: the Authorization header is forwarded, never
stored or injected.

Usage:
  kimo-chat-proxy.py --upstream https://host/api/ai/openai/v1 \\
      --port-file /tmp/kimo-chat.XXXXXX [--exit-with-pid PID]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Written with escapes so markup stripping cannot eat the tag delimiters.
OPEN_TAG = "\u003cthink\u003e"
CLOSE_TAG = "\u003c/think\u003e"
# Longest tag prefix held back when a chunk ends mid-tag.
TAG_HOLD = max(len(OPEN_TAG), len(CLOSE_TAG)) - 1

# Templates that open the assistant turn inside ` thinking`, so the output has
# no opener and only a bare close. Kept to families verified to behave that
# way; a model that answers directly would otherwise have its answer read as
# reasoning. Code variants are excluded because they do not reason at all.
OPENS_IN_PROMPT = re.compile(
    r"qwen-?3(?!.*coder)|qwq|deepseek-r1|deepseek-reasoner|"
    r"(?:^|[-_/])r1(?:$|[-_/.:])|reasoner|thinking",
    re.IGNORECASE,
)


def opens_in_prompt(model: object) -> bool:
    return isinstance(model, str) and OPENS_IN_PROMPT.search(model) is not None


def _prefix_hold(text: str) -> int:
    """Longest suffix of text that could be the start of a think tag."""
    lower = text.lower()
    for length in range(min(len(lower), TAG_HOLD), 0, -1):
        suffix = lower[-length:]
        if OPEN_TAG.startswith(suffix) or CLOSE_TAG.startswith(suffix):
            return length
    return 0


class InlineThinkSplitter:
    """Streaming `content` -> (reasoning_content, content) splitter.

    A template-opened model starts in reasoning mode: everything is reasoning
    until the bare close, then the answer. Other models start in answer mode
    and are split on explicit ` thinking`/`` blocks. Partial tags are
    held back across chunk boundaries; ordinary text such as "2 < 3" is never
    swallowed.
    """

    def __init__(self, model: object = None, reasoning_effort: object = None):
        effort = reasoning_effort if isinstance(reasoning_effort, str) else ""
        self.mode = "think" if opens_in_prompt(model) and effort.lower() not in ("none", "off") else "answer"
        self.hold = ""
        self.trim_answer = False
        self.trim_think = True

    def _emit(self, text: str, out: list[tuple[str, str]]) -> None:
        if not text:
            return
        if self.mode == "think":
            if self.trim_think:
                text = text.lstrip()
                if not text:
                    return
                self.trim_think = False
            out.append(("reasoning_content", text))
            return
        if self.trim_answer:
            text = text.lstrip()
            if not text:
                return
            self.trim_answer = False
        out.append(("content", text))

    def feed(self, piece: object) -> list[tuple[str, str]]:
        if not isinstance(piece, str) or not piece:
            return []
        out: list[tuple[str, str]] = []
        buf = self.hold + piece
        self.hold = ""
        while buf:
            tag = CLOSE_TAG if self.mode == "think" else OPEN_TAG
            index = buf.lower().find(tag)
            if index != -1:
                self._emit(buf[:index], out)
                buf = buf[index + len(tag):]
                if tag == CLOSE_TAG:
                    self.mode = "answer"
                    self.trim_answer = True
                else:
                    self.mode = "think"
                    self.trim_think = True
                continue
            keep = _prefix_hold(buf)
            self._emit(buf[: len(buf) - keep], out)
            self.hold = buf[len(buf) - keep:]
            break
        return out

    def finish(self) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        if self.hold:
            piece, self.hold = self.hold, ""
            self._emit(piece, out)
        return out


def split_inline(text: object, model: object = None, reasoning_effort: object = None) -> dict:
    """Split a whole reply into `content` and `reasoning_content`."""
    splitter = InlineThinkSplitter(model, reasoning_effort)
    parts = splitter.feed(text)
    parts.extend(splitter.finish())
    answer = "".join(piece for kind, piece in parts if kind == "content")
    thinking = "".join(piece for kind, piece in parts if kind == "reasoning_content")
    return {"content": answer, "reasoning_content": thinking}


def _field(body: object, name: str) -> object:
    return body.get(name) if isinstance(body, dict) else None


def _effort_of(body: object) -> object:
    effort = _field(body, "reasoning_effort")
    if isinstance(effort, str):
        return effort
    reasoning = _field(body, "reasoning")
    if isinstance(reasoning, dict) and isinstance(reasoning.get("effort"), str):
        return reasoning["effort"]
    return None


def _choice_chunk(payload: dict, index: int, delta: dict, finish_reason=None) -> dict:
    chunk = {key: value for key, value in payload.items() if key != "choices"}
    chunk["choices"] = [{"index": index, "delta": delta, "finish_reason": finish_reason}]
    return chunk


class Transform:
    """Per-response state: one splitter per choice index."""

    def __init__(self, model: object, effort: object):
        self.model = model
        self.effort = effort
        self.splitters: dict[int, InlineThinkSplitter] = {}
        self.last_payload: dict = {}

    def splitter(self, index: int) -> InlineThinkSplitter:
        split = self.splitters.get(index)
        if split is None:
            split = InlineThinkSplitter(self.model, self.effort)
            self.splitters[index] = split
        return split

    def chat(self, payload: object) -> object:
        if not isinstance(payload, dict) or not isinstance(payload.get("choices"), list):
            return payload
        for choice in payload["choices"]:
            if not isinstance(choice, dict):
                continue
            message = choice.get("message")
            if isinstance(message, dict) and isinstance(message.get("content"), str):
                split = split_inline(message["content"], self.model, self.effort)
                message["content"] = split["content"]
                if split["reasoning_content"]:
                    message["reasoning_content"] = (
                        (message.get("reasoning_content") or "") + split["reasoning_content"]
                    )
        return payload

    def finish_all(self) -> list[dict]:
        """Flush held text for every choice, for a stream that ends at [DONE]."""
        chunks = []
        for index, split in self.splitters.items():
            parts = split.finish()
            reasoning = "".join(piece for kind, piece in parts if kind == "reasoning_content")
            content = "".join(piece for kind, piece in parts if kind == "content")
            if reasoning:
                chunks.append(_choice_chunk(self.last_payload, index, {"reasoning_content": reasoning}))
            if content:
                chunks.append(_choice_chunk(self.last_payload, index, {"content": content}))
        return chunks

    def chunk(self, payload: object) -> list[dict]:
        """Return the OpenAI chunks to emit for one upstream chunk."""
        if not isinstance(payload, dict) or not isinstance(payload.get("choices"), list):
            return [payload]
        self.last_payload = payload
        out: list[dict] = []
        for choice in payload["choices"]:
            if not isinstance(choice, dict):
                continue
            index = choice.get("index", 0)
            if not isinstance(index, int) or isinstance(index, bool):
                index = 0
            delta = choice.get("delta")
            finish_reason = choice.get("finish_reason")
            finish = finish_reason is not None
            if not isinstance(delta, dict):
                out.append(payload)
                continue
            if delta.get("reasoning_content"):
                # The upstream already separates it; never re-split.
                out.append(payload)
                continue
            base = {key: value for key, value in delta.items() if key not in ("content", "reasoning_content")}
            parts = self.splitter(index).feed(delta.get("content"))
            if finish:
                parts.extend(self.splitter(index).finish())
            reasoning = "".join(piece for kind, piece in parts if kind == "reasoning_content")
            content = "".join(piece for kind, piece in parts if kind == "content")
            if reasoning and content:
                out.append(_choice_chunk(payload, index, {**base, "reasoning_content": reasoning}))
                out.append(_choice_chunk(payload, index, {"content": content},
                                         finish_reason if finish else None))
            elif reasoning:
                out.append(_choice_chunk(payload, index, {**base, "reasoning_content": reasoning},
                                         finish_reason if finish else None))
            elif content:
                out.append(_choice_chunk(payload, index, {**base, "content": content},
                                         finish_reason if finish else None))
            elif base:
                out.append(_choice_chunk(payload, index, base, finish_reason if finish else None))
            elif finish:
                out.append(_choice_chunk(payload, index, {}, finish_reason))
        return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""

    def log_message(self, fmt, *args):
        return

    def _url(self) -> str:
        path = self.path or "/"
        if path.startswith("/v1/"):
            path = path[3:]
        elif path == "/v1":
            path = "/"
        return self.upstream.rstrip("/") + "/" + path.lstrip("/")

    def _forward_headers(self) -> dict:
        skip = {"host", "content-length", "connection", "transfer-encoding",
                "accept-encoding", "keep-alive", "proxy-connection"}
        out = {}
        for name in self.headers:
            if name.lower() in skip:
                continue
            out[name] = self.headers.get(name)
        out["accept-encoding"] = "identity"
        return out

    def _send_json(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("content-type", content_type or "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _error(self, status: int, message: str) -> None:
        body = json.dumps({"error": {"message": message, "type": "api_error",
                                     "code": "proxy_error"}}).encode()
        self._send_json(status, body, "application/json")

    def do_GET(self):
        self._relay(b"")

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        self._relay(body)

    def _relay(self, body: bytes) -> None:
        request = urllib.request.Request(
            self._url(),
            data=body if self.command == "POST" else None,
            headers=self._forward_headers(),
            method=self.command,
        )
        try:
            upstream = urllib.request.urlopen(request, timeout=900)
        except urllib.error.HTTPError as error:
            payload = error.read()
            self._send_json(error.code, payload, error.headers.get("content-type", "application/json"))
            return
        except Exception as error:  # connection refused, DNS, timeout
            self._error(502, f"chat proxy could not reach the upstream: {error}")
            return

        try:
            request_body = json.loads(body) if body else {}
        except ValueError:
            request_body = {}
        transform = Transform(_field(request_body, "model"), _effort_of(request_body))

        content_type = upstream.headers.get("content-type", "")
        if "text/event-stream" not in content_type.lower():
            try:
                payload = upstream.read()
            except Exception as error:
                self._error(502, f"chat proxy read failed: {error}")
                return
            if "json" in content_type.lower():
                try:
                    payload = json.dumps(transform.chat(json.loads(payload))).encode()
                except ValueError:
                    pass
            self._send_json(upstream.status, payload, content_type or "application/json")
            return

        self.send_response(upstream.status)
        self.send_header("content-type", content_type or "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        self.close_connection = True

        buffer = b""
        while True:
            try:
                block = upstream.read(4096)
            except Exception:
                break
            if not block:
                break
            buffer += block
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                self._write_line(line, transform)
        if buffer:
            self._write_line(buffer, transform)

    def _write_line(self, line: bytes, transform: Transform) -> None:
        stripped = line.rstrip(b"\r")
        if not stripped.startswith(b"data:"):
            return
        raw = stripped[5:].strip()
        if not raw or raw == b"[DONE]":
            if raw == b"[DONE]":
                for chunk in transform.finish_all():
                    self.wfile.write(b"data: " + json.dumps(chunk, separators=(",", ":")).encode() + b"\n\n")
            self.wfile.write(stripped + b"\n\n")
            self.wfile.flush()
            return
        try:
            payload = json.loads(raw)
        except ValueError:
            self.wfile.write(stripped + b"\n\n")
            self.wfile.flush()
            return
        for chunk in transform.chunk(payload):
            encoded = json.dumps(chunk, separators=(",", ":")).encode()
            self.wfile.write(b"data: " + encoded + b"\n\n")
        self.wfile.flush()


def _watch_parent(pid: int) -> None:
    while True:
        time.sleep(1)
        try:
            os.kill(pid, 0)
        except OSError:
            os._exit(0)


def main() -> int:
    parser = argparse.ArgumentParser(description="loopback OpenAI chat relay")
    parser.add_argument("--upstream", required=True, help="OpenAI base URL to relay to")
    parser.add_argument("--port-file", required=True, help="file to receive the listening port")
    parser.add_argument("--exit-with-pid", type=int, default=0, help="exit when this pid disappears")
    args = parser.parse_args()

    Handler.upstream = args.upstream
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    if args.exit_with_pid > 0:
        threading.Thread(target=_watch_parent, args=(args.exit_with_pid,), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())