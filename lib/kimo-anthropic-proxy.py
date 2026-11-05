#!/usr/bin/env python3
"""Local Anthropic Messages proxy for `kimo launch claude --provider`.

Claude Code posts `/v1/messages`. OpenAI, the ChatGPT Codex backend, xAI,
QwenCloud, Gemini's OpenAI surface and vLLM do not speak that wire. This
process binds 127.0.0.1, checks a per-launch client token, and translates
one request into either Chat Completions or the Responses API.

The upstream credential is read from the environment variable named by
--env-key. It is never taken from the client, never written to disk, and
redacted if an upstream error echoes it. The process exits when
--exit-with-pid disappears (kimo execs Claude, so that pid is Claude's).
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import re
import sys
import threading
import time
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable
from urllib.parse import urlsplit

MAX_BODY = 32 * 1024 * 1024
SUFFIX = re.compile(r"\[[^\[\]]+\]$")
MESSAGE_PATHS = {"/v1/messages", "/messages"}
COUNT_PATHS = {"/v1/messages/count_tokens", "/messages/count_tokens"}


class ProxyError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def bare_model(model: object) -> str:
    text = model if isinstance(model, str) else ""
    text = SUFFIX.sub("", text).strip()
    return text or "claude"


def same_token(got: str, want: str) -> bool:
    if not got or not want:
        return False
    return hmac.compare_digest(got.encode(), want.encode())


def presented_token(headers) -> str:
    auth = headers.get("Authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return (headers.get("x-api-key") or "").strip()


def jwt_account(token: str) -> str:
    parts = token.split(".")
    if len(parts) < 2:
        return ""
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError):
        return ""
    auth = data.get("https://api.openai.com/auth") if isinstance(data, dict) else None
    if not isinstance(auth, dict):
        return ""
    account = auth.get("chatgpt_account_id")
    return account if isinstance(account, str) else ""


def grok_cli_host(url: str) -> bool:
    """True for the Grok CLI session proxy, not the public api.x.ai host.

    A `grok login` JWT is only accepted there, and only on Chat Completions.
    """
    host = (urlsplit(url).hostname or "").lower()
    return host == "cli-chat-proxy.grok.com" or host.endswith(".grok.com")


def grok_session_headers(upstream: str, payload: dict) -> dict:
    """Headers cli-chat-proxy.grok.com requires on top of the bearer token."""
    if not grok_cli_host(upstream):
        return {}
    headers = {"X-XAI-Token-Auth": "xai-grok-cli"}
    model_name = payload.get("model")
    if isinstance(model_name, str) and model_name:
        headers["x-grok-model-override"] = model_name
    return headers


def redact(text: str, secret: str) -> str:
    if secret and secret in text:
        text = text.replace(secret, "[redacted]")
    return text[:800]


def estimate_tokens(payload: dict) -> int:
    return max(1, len(json.dumps(payload, separators=(",", ":"))) // 4)


def _as_list(content: object) -> list:
    if isinstance(content, list):
        return [item for item in content if isinstance(item, dict)]
    return []


def _text_pieces(content: object) -> list[str]:
    if isinstance(content, str):
        return [content] if content else []
    pieces = []
    for block in _as_list(content):
        if block.get("type") in ("text", "input_text", "output_text") and isinstance(block.get("text"), str):
            pieces.append(block["text"])
    return pieces


def _thinking_pieces(content: object) -> list[str]:
    pieces = []
    for block in _as_list(content):
        if block.get("type") == "thinking" and isinstance(block.get("thinking"), str):
            pieces.append(block["thinking"])
    return pieces


def _image_urls(content: object) -> list[str]:
    urls = []
    for block in _as_list(content):
        if block.get("type") != "image":
            continue
        source = block.get("source")
        if not isinstance(source, dict):
            continue
        if source.get("type") == "base64" and isinstance(source.get("data"), str):
            media = source.get("media_type") if isinstance(source.get("media_type"), str) else "image/png"
            urls.append(f"data:{media};base64,{source['data']}")
        elif source.get("type") == "url" and isinstance(source.get("url"), str):
            urls.append(source["url"])
    return urls


def _tool_uses(content: object) -> list[dict]:
    found = []
    for block in _as_list(content):
        if block.get("type") != "tool_use":
            continue
        name = block.get("name") if isinstance(block.get("name"), str) else ""
        tool_id = block.get("id") if isinstance(block.get("id"), str) else ""
        if not name or not tool_id:
            continue
        raw_input = block.get("input")
        if not isinstance(raw_input, (dict, list)):
            raw_input = {}
        found.append({"id": tool_id, "name": name, "arguments": json.dumps(raw_input, separators=(",", ":"))})
    return found


def _tool_results(content: object) -> list[tuple[str, str]]:
    found = []
    for block in _as_list(content):
        if block.get("type") != "tool_result":
            continue
        tool_id = block.get("tool_use_id") if isinstance(block.get("tool_use_id"), str) else ""
        if not tool_id:
            continue
        body = block.get("content")
        if isinstance(body, str):
            text = body
        else:
            text = "".join(_text_pieces(body))
        found.append((tool_id, text))
    return found


def _schema(tool: dict) -> dict:
    schema = tool.get("input_schema")
    return schema if isinstance(schema, dict) else {"type": "object", "properties": {}}


def _tools(raw: object, wire: str) -> list[dict]:
    tools = []
    if not isinstance(raw, list):
        return tools
    for tool in raw:
        if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) or not tool["name"]:
            continue
        description = tool.get("description") if isinstance(tool.get("description"), str) else ""
        schema = _schema(tool)
        if wire == "chat":
            tools.append({
                "type": "function",
                "function": {"name": tool["name"], "description": description, "parameters": schema},
            })
        else:
            tools.append({
                "type": "function",
                "name": tool["name"],
                "description": description,
                "parameters": schema,
            })
    return tools


def _tool_choice(choice: object, wire: str):
    if choice is None:
        return None
    if isinstance(choice, str) and choice in ("auto", "none", "required"):
        return choice
    if not isinstance(choice, dict):
        return None
    kind = choice.get("type")
    if kind == "auto":
        return "auto"
    if kind == "none":
        return "none"
    if kind == "any":
        return "required"
    if kind == "tool" and isinstance(choice.get("name"), str):
        if wire == "chat":
            return {"type": "function", "function": {"name": choice["name"]}}
        return {"type": "function", "name": choice["name"]}
    return None


def _system_text(system: object) -> str:
    if isinstance(system, str):
        return system
    return "\n".join(_text_pieces(system))


def to_chat(payload: dict) -> dict:
    messages = []
    system = _system_text(payload.get("system"))
    if system:
        messages.append({"role": "system", "content": system})
    for message in payload.get("messages") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role == "user":
            for tool_id, text in _tool_results(content):
                messages.append({"role": "tool", "tool_call_id": tool_id, "content": text})
            parts = []
            for piece in _text_pieces(content):
                parts.append({"type": "text", "text": piece})
            for url in _image_urls(content):
                parts.append({"type": "image_url", "image_url": {"url": url}})
            if parts:
                messages.append({"role": "user", "content": parts if len(parts) > 1 or parts[0]["type"] != "text" else parts[0]["text"]})
            elif isinstance(content, str) and content:
                messages.append({"role": "user", "content": content})
        elif role == "assistant":
            item = {"role": "assistant", "content": "".join(_text_pieces(content))}
            thinking = "".join(_thinking_pieces(content))
            if thinking:
                item["reasoning_content"] = thinking
            calls = []
            for call in _tool_uses(content):
                calls.append({
                    "id": call["id"],
                    "type": "function",
                    "function": {"name": call["name"], "arguments": call["arguments"]},
                })
            if calls:
                item["tool_calls"] = calls
            messages.append(item)
    out = {
        "model": bare_model(payload.get("model")),
        "messages": messages,
        "stream": bool(payload.get("stream")),
    }
    if isinstance(payload.get("max_tokens"), int) and payload["max_tokens"] > 0:
        out["max_tokens"] = payload["max_tokens"]
    if isinstance(payload.get("temperature"), (int, float)) and not isinstance(payload.get("temperature"), bool):
        out["temperature"] = payload["temperature"]
    if isinstance(payload.get("top_p"), (int, float)) and not isinstance(payload.get("top_p"), bool):
        out["top_p"] = payload["top_p"]
    stops = payload.get("stop_sequences")
    if isinstance(stops, list) and stops and all(isinstance(item, str) for item in stops):
        out["stop"] = stops
    tools = _tools(payload.get("tools"), "chat")
    if tools:
        out["tools"] = tools
    choice = _tool_choice(payload.get("tool_choice"), "chat")
    if choice is not None:
        out["tool_choice"] = choice
    return out


def to_responses(payload: dict) -> dict:
    items = []
    for message in payload.get("messages") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role == "user":
            for tool_id, text in _tool_results(content):
                items.append({"type": "function_call_output", "call_id": tool_id, "output": text})
            parts = [{"type": "input_text", "text": piece} for piece in _text_pieces(content)]
            parts.extend({"type": "input_image", "image_url": url} for url in _image_urls(content))
            if not parts and isinstance(content, str) and content:
                parts = [{"type": "input_text", "text": content}]
            if parts:
                items.append({"type": "message", "role": "user", "content": parts})
        elif role == "assistant":
            text = "".join(_text_pieces(content))
            if text:
                items.append({
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": text}],
                })
            for call in _tool_uses(content):
                items.append({
                    "type": "function_call",
                    "call_id": call["id"],
                    "name": call["name"],
                    "arguments": call["arguments"],
                })
    out = {
        "model": bare_model(payload.get("model")),
        "input": items,
        "stream": bool(payload.get("stream")),
        "store": False,
    }
    system = _system_text(payload.get("system"))
    if system:
        out["instructions"] = system
    if isinstance(payload.get("max_tokens"), int) and payload["max_tokens"] > 0:
        out["max_output_tokens"] = payload["max_tokens"]
    tools = _tools(payload.get("tools"), "responses")
    if tools:
        out["tools"] = tools
    choice = _tool_choice(payload.get("tool_choice"), "responses")
    if choice is not None:
        out["tool_choice"] = choice
    return out


def _parse_input(raw: str):
    text = (raw or "").strip()
    if not text:
        return {}
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {"value": value}


class Builder:
    """Accumulate Anthropic content blocks and optionally emit them as SSE."""

    def __init__(self, model: str, emit: Callable[[str, dict], None] | None = None):
        self.model = model
        self.emit = emit
        self.blocks: list[dict] = []
        self.open_index: int | None = None
        self.tools: dict[int, int] = {}
        self.started = False
        self.finish_reason = ""
        self.input_tokens = 1
        self.output_tokens = 1
        self.msg_id = "msg_kimo"

    def note_usage(self, incoming: object, outgoing: object) -> None:
        if isinstance(incoming, int) and not isinstance(incoming, bool) and incoming > 0:
            self.input_tokens = incoming
        if isinstance(outgoing, int) and not isinstance(outgoing, bool) and outgoing > 0:
            self.output_tokens = outgoing

    def mark_finish(self, reason: object) -> None:
        if isinstance(reason, str) and reason:
            self.finish_reason = reason

    def _send(self, event: str, data: dict) -> None:
        if self.emit is not None:
            self.emit(event, data)

    def _message_start(self) -> None:
        if self.started:
            return
        self.started = True
        self._send("message_start", {
            "type": "message_start",
            "message": {
                "id": self.msg_id,
                "type": "message",
                "role": "assistant",
                "content": [],
                "model": self.model,
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": self.input_tokens, "output_tokens": 0},
            },
        })

    def _close_open(self) -> None:
        if self.open_index is None:
            return
        self._send("content_block_stop", {"type": "content_block_stop", "index": self.open_index})
        self.open_index = None

    def _open_text(self, kind: str) -> dict:
        self._message_start()
        if self.open_index is not None and self.blocks[self.open_index]["type"] == kind:
            return self.blocks[self.open_index]
        self._close_open()
        block = {"type": kind, kind: ""}
        self.blocks.append(block)
        self.open_index = len(self.blocks) - 1
        content = {"type": kind, kind: ""}
        self._send("content_block_start", {
            "type": "content_block_start",
            "index": self.open_index,
            "content_block": content,
        })
        return block

    def text(self, piece: object) -> None:
        if not isinstance(piece, str) or not piece:
            return
        block = self._open_text("text")
        block["text"] += piece
        self._send("content_block_delta", {
            "type": "content_block_delta",
            "index": self.open_index,
            "delta": {"type": "text_delta", "text": piece},
        })

    def thinking(self, piece: object) -> None:
        if not isinstance(piece, str) or not piece:
            return
        block = self._open_text("thinking")
        block["thinking"] += piece
        self._send("content_block_delta", {
            "type": "content_block_delta",
            "index": self.open_index,
            "delta": {"type": "thinking_delta", "thinking": piece},
        })

    def tool_delta(self, index: object, tool_id: object, name: object, arguments: object) -> None:
        self._message_start()
        slot = index if isinstance(index, int) and not isinstance(index, bool) else 0
        if slot not in self.tools:
            self._close_open()
            block = {
                "type": "tool_use",
                "id": tool_id if isinstance(tool_id, str) and tool_id else f"toolu_{len(self.blocks)}",
                "name": name if isinstance(name, str) and name else "tool",
                "raw": "",
            }
            self.blocks.append(block)
            self.tools[slot] = len(self.blocks) - 1
            self.open_index = self.tools[slot]
            self._send("content_block_start", {
                "type": "content_block_start",
                "index": self.open_index,
                "content_block": {"type": "tool_use", "id": block["id"], "name": block["name"], "input": {}},
            })
        block = self.blocks[self.tools[slot]]
        if isinstance(tool_id, str) and tool_id:
            block["id"] = tool_id
        if isinstance(name, str) and name and block["name"] == "tool":
            block["name"] = name
        fragment = arguments if isinstance(arguments, str) else ""
        if not fragment:
            return
        block["raw"] += fragment
        self._send("content_block_delta", {
            "type": "content_block_delta",
            "index": self.tools[slot],
            "delta": {"type": "input_json_delta", "partial_json": fragment},
        })

    def stop_reason(self) -> str:
        if self.finish_reason in ("length", "max_tokens"):
            return "max_tokens"
        if self.finish_reason in ("tool_calls", "tool_use") or self.tools:
            return "tool_use"
        return "end_turn"

    def finish(self) -> None:
        self._message_start()
        self._close_open()
        self._send("message_delta", {
            "type": "message_delta",
            "delta": {"stop_reason": self.stop_reason(), "stop_sequence": None},
            "usage": {"output_tokens": self.output_tokens},
        })
        self._send("message_stop", {"type": "message_stop"})

    def as_message(self) -> dict:
        content = []
        for block in self.blocks:
            if block["type"] == "text":
                content.append({"type": "text", "text": block["text"]})
            elif block["type"] == "thinking":
                content.append({"type": "thinking", "thinking": block["thinking"]})
            else:
                content.append({
                    "type": "tool_use",
                    "id": block["id"],
                    "name": block["name"],
                    "input": _parse_input(block["raw"]),
                })
        return {
            "id": self.msg_id,
            "type": "message",
            "role": "assistant",
            "model": self.model,
            "content": content,
            "stop_reason": self.stop_reason(),
            "stop_sequence": None,
            "usage": {"input_tokens": self.input_tokens, "output_tokens": self.output_tokens},
        }


def _usage_pair(usage: object) -> tuple[object, object]:
    if not isinstance(usage, dict):
        return None, None
    incoming = usage.get("prompt_tokens", usage.get("input_tokens"))
    outgoing = usage.get("completion_tokens", usage.get("output_tokens"))
    return incoming, outgoing


def apply_chat_chunk(builder: Builder, chunk: dict) -> None:
    builder.note_usage(*_usage_pair(chunk.get("usage")))
    choices = chunk.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return
    choice = choices[0]
    delta = choice.get("delta") if isinstance(choice.get("delta"), dict) else {}
    builder.thinking(delta.get("reasoning_content"))
    builder.text(delta.get("content"))
    calls = delta.get("tool_calls")
    if isinstance(calls, list):
        for call in calls:
            if not isinstance(call, dict):
                continue
            function = call.get("function") if isinstance(call.get("function"), dict) else {}
            builder.tool_delta(call.get("index", 0), call.get("id"), function.get("name"), function.get("arguments"))
    builder.mark_finish(choice.get("finish_reason"))


def apply_chat_message(builder: Builder, payload: dict) -> None:
    builder.note_usage(*_usage_pair(payload.get("usage")))
    choices = payload.get("choices")
    choice = choices[0] if isinstance(choices, list) and choices and isinstance(choices[0], dict) else {}
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    builder.thinking(message.get("reasoning_content"))
    builder.text(message.get("content"))
    calls = message.get("tool_calls")
    if isinstance(calls, list):
        for index, call in enumerate(calls):
            if not isinstance(call, dict):
                continue
            function = call.get("function") if isinstance(call.get("function"), dict) else {}
            builder.tool_delta(index, call.get("id"), function.get("name"), function.get("arguments"))
    builder.mark_finish(choice.get("finish_reason") or "stop")


def apply_responses_event(builder: Builder, event: dict) -> None:
    kind = event.get("type") if isinstance(event.get("type"), str) else ""
    if kind in ("response.output_text.delta", "response.refusal.delta"):
        builder.text(event.get("delta"))
    elif kind in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta"):
        builder.thinking(event.get("delta"))
    elif kind == "response.output_item.added":
        item = event.get("item") if isinstance(event.get("item"), dict) else {}
        if item.get("type") == "function_call":
            builder.tool_delta(event.get("output_index", 0), item.get("call_id") or item.get("id"), item.get("name"), "")
            builder.tool_delta(event.get("output_index", 0), "", "", item.get("arguments") if isinstance(item.get("arguments"), str) else "")
    elif kind == "response.function_call_arguments.delta":
        builder.tool_delta(event.get("output_index", 0), "", "", event.get("delta"))
    elif kind in ("response.completed", "response.incomplete"):
        response = event.get("response") if isinstance(event.get("response"), dict) else {}
        builder.note_usage(*_usage_pair(response.get("usage")))
        builder.mark_finish("length" if response.get("status") == "incomplete" or kind == "response.incomplete" else "stop")
    elif kind in ("response.failed", "error"):
        error = event.get("error") if isinstance(event.get("error"), dict) else {}
        response = event.get("response") if isinstance(event.get("response"), dict) else {}
        nested = response.get("error") if isinstance(response.get("error"), dict) else {}
        message = error.get("message") or nested.get("message") or "upstream response failed"
        raise ProxyError(502, message if isinstance(message, str) else "upstream response failed")


def apply_responses_message(builder: Builder, payload: dict) -> None:
    builder.note_usage(*_usage_pair(payload.get("usage")))
    output = payload.get("output") if isinstance(payload.get("output"), list) else []
    for index, item in enumerate(output):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "message":
            for part in item.get("content") or []:
                if not isinstance(part, dict):
                    continue
                if part.get("type") in ("output_text", "text"):
                    builder.text(part.get("text"))
                elif part.get("type") == "refusal":
                    builder.text(part.get("refusal"))
        elif item.get("type") == "function_call":
            builder.tool_delta(index, item.get("call_id") or item.get("id"), item.get("name"), item.get("arguments"))
        elif item.get("type") == "reasoning":
            for part in item.get("summary") or []:
                if isinstance(part, dict):
                    builder.thinking(part.get("text"))
    builder.mark_finish("length" if payload.get("status") == "incomplete" else "stop")


def iter_sse(response):
    """Yield JSON objects from an SSE body. Stops at EOF or a chat [DONE]."""
    while True:
        raw = response.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data:
            continue
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            yield event


def error_body(status: int, message: str) -> bytes:
    kind = {
        400: "invalid_request_error",
        401: "authentication_error",
        403: "permission_error",
        404: "not_found_error",
        413: "invalid_request_error",
        429: "rate_limit_error",
        529: "overloaded_error",
    }.get(status, "api_error")
    if status >= 500 and status not in (529,):
        kind = "api_error"
    return json.dumps({"type": "error", "error": {"type": kind, "message": message}}).encode()


class Proxy(BaseHTTPRequestHandler):
    upstream = ""
    wire = "chat"
    env_key = ""
    provider = ""
    client_token = ""
    timeout = 600

    def do_POST(self) -> None:
        try:
            self._handle()
        except ProxyError as exc:
            self._json(exc.status, error_body(exc.status, redact(exc.message, self._secret())))
        except Exception as exc:  # noqa: BLE001 - last-resort client error, never a traceback
            self._json(500, error_body(500, redact(str(exc), self._secret())))

    def do_GET(self) -> None:
        self._json(404, error_body(404, "not found"))

    def _secret(self) -> str:
        if not self.env_key:
            return ""
        return os.environ.get(self.env_key, "")

    def _authorized(self) -> bool:
        return same_token(presented_token(self.headers), self.client_token)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length < 0 or length > MAX_BODY:
            raise ProxyError(413, "request body is too large")
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ProxyError(400, f"request body is not JSON ({exc})") from exc
        if not isinstance(payload, dict):
            raise ProxyError(400, "request body must be a JSON object")
        return payload

    def _handle(self) -> None:
        if not self._authorized():
            raise ProxyError(401, "invalid proxy token")
        path = urlsplit(self.path).path.rstrip("/") or "/"
        payload = self._read_json()
        if path in COUNT_PATHS:
            self._json(200, json.dumps({"input_tokens": estimate_tokens(payload)}).encode())
            return
        if path not in MESSAGE_PATHS:
            raise ProxyError(404, "not found")
        model = bare_model(payload.get("model"))
        # A grok-login JWT is aimed at cli-chat-proxy.grok.com. That host speaks
        # Chat Completions, routes on x-grok-model-override, and requires
        # X-XAI-Token-Auth. Responses on that host 401s with x_xai_token_auth=none.
        wire = "chat" if grok_cli_host(self.upstream) else self.wire
        translated = to_chat(payload) if wire == "chat" else to_responses(payload)
        client_stream = bool(payload.get("stream"))
        if wire == "chat" and grok_cli_host(self.upstream):
            translated["stream"] = True
        secret = self._secret()
        if self.env_key and not secret:
            raise ProxyError(502, f"{self.env_key} is empty; the upstream credential is missing")
        conn, upstream = self._open(translated, secret, wire)
        try:
            if upstream.status >= 400:
                message = upstream.read(MAX_BODY).decode("utf-8", "replace")
                try:
                    parsed = json.loads(message)
                    if isinstance(parsed, dict):
                        error = parsed.get("error")
                        if isinstance(error, dict) and isinstance(error.get("message"), str):
                            message = error["message"]
                        elif isinstance(parsed.get("message"), str):
                            message = parsed["message"]
                except json.JSONDecodeError:
                    pass
                mapped = upstream.status if upstream.status in (400, 401, 403, 404, 429) else 502
                raise ProxyError(mapped, message.strip() or f"upstream HTTP {upstream.status}")
            upstream_stream = bool(translated.get("stream"))
            builder = Builder(model, self._sse_emit if client_stream else None)
            builder.input_tokens = estimate_tokens(payload)
            if upstream_stream and client_stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                try:
                    for event in iter_sse(upstream):
                        if wire == "responses":
                            apply_responses_event(builder, event)
                        else:
                            apply_chat_chunk(builder, event)
                    builder.finish()
                except ProxyError as exc:
                    # Headers are already on the wire. Surface the failure as a
                    # terminal SSE error so Claude does not wait out the timeout.
                    self._sse_emit("error", {"type": "error", "error": {"type": "api_error", "message": redact(exc.message, secret)}})
                return
            if upstream_stream:
                # The CLI proxy only streams. Fold that SSE into one Messages
                # object when Claude itself asked for a non-stream response.
                for event in iter_sse(upstream):
                    if wire == "responses":
                        apply_responses_event(builder, event)
                    else:
                        apply_chat_chunk(builder, event)
                self._json(200, json.dumps(builder.as_message()).encode())
                return
            try:
                parsed = json.loads(upstream.read(MAX_BODY).decode("utf-8"))
            except json.JSONDecodeError as exc:
                raise ProxyError(502, f"upstream did not return JSON ({exc})") from exc
            if not isinstance(parsed, dict):
                raise ProxyError(502, "upstream JSON was not an object")
            if wire == "responses":
                apply_responses_message(builder, parsed)
            else:
                apply_chat_message(builder, parsed)
            self._json(200, json.dumps(builder.as_message()).encode())
        finally:
            conn.close()

    def _open(self, payload: dict, secret: str, wire: str):
        parts = urlsplit(self.upstream.rstrip("/"))
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ProxyError(502, "upstream URL is not http(s)")
        path = (parts.path.rstrip("/") or "") + ("/responses" if wire == "responses" else "/chat/completions")
        data = json.dumps(payload, separators=(",", ":")).encode()
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream, application/json",
            "Content-Length": str(len(data)),
            "Host": parts.netloc,
        }
        if secret and secret != "EMPTY":
            headers["Authorization"] = f"Bearer {secret}"
            if secret.startswith("AIzaSy"):
                headers["x-goog-api-key"] = secret
        if self.provider == "xai" or (parts.hostname or "").endswith("grok.com"):
            headers["X-Grok-Client-Version"] = "1.0.70"
        # Without X-XAI-Token-Auth the CLI proxy reports
        # auth_kind=bearer, x_xai_token_auth=none, reason=no auth context.
        headers.update(grok_session_headers(self.upstream, payload))
        if self.provider == "codex":
            account = jwt_account(secret)
            if account:
                headers["Chatgpt-Account-Id"] = account
        connection_cls = HTTPSConnection if parts.scheme == "https" else HTTPConnection
        port = parts.port or (443 if parts.scheme == "https" else 80)
        try:
            conn = connection_cls(parts.hostname, port, timeout=self.timeout)
            conn.request("POST", path, body=data, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            raise ProxyError(502, f"upstream unreachable: {exc}") from exc
        return conn, upstream

    def _sse_emit(self, event: str, data: dict) -> None:
        raw = f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()
        try:
            self.wfile.write(raw)
            self.wfile.flush()
        except BrokenPipeError:
            return

    def _json(self, status: int, body: bytes) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def log_message(self, fmt: str, *args) -> None:
        return


def _watch_pid(pid: int) -> None:
    while True:
        time.sleep(1)
        try:
            os.kill(pid, 0)
        except OSError:
            os._exit(0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Translate Anthropic Messages to an OpenAI-compatible upstream")
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--wire", choices=("chat", "responses"), required=True)
    parser.add_argument("--env-key", default="")
    parser.add_argument("--provider", default="")
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--exit-with-pid", type=int, required=True)
    parser.add_argument("--client-token-env", default="KIMO_ANTHROPIC_PROXY_CLIENT")
    args = parser.parse_args()
    parts = urlsplit(args.upstream)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        print(f"anthropic proxy: upstream must be an http(s) URL (got {args.upstream})", file=sys.stderr)
        return 1
    token = os.environ.get(args.client_token_env, "")
    if not token:
        print("anthropic proxy: client token env is empty", file=sys.stderr)
        return 1
    Proxy.upstream = args.upstream.rstrip("/")
    Proxy.wire = args.wire
    Proxy.env_key = args.env_key
    Proxy.provider = args.provider
    Proxy.client_token = token
    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    port = server.server_address[1]
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    threading.Thread(target=_watch_pid, args=(args.exit_with_pid,), daemon=True).start()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
