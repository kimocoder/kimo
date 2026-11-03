#!/usr/bin/env python3
"""
ollama-gemini-shim.py – Gemini wire-format translation shim.

Enables Google Antigravity (agy) and other Gemini-only CLI clients to seamlessly
interface with native and remote Ollama instances without external proxies.

Two upstream wires, picked with --upstream-kind:
  - ollama (default)  {upstream}/api/chat, NDJSON stream, {upstream}/api/tags
  - openai            {upstream}/chat/completions, SSE stream, {upstream}/models
The openai kind is what reaches a hosted OpenAI-compatible API such as Alibaba
Model Studio's compatible-mode surface, which has no Gemini endpoint and no
/api/chat. Its sampling controls sit at the top level of the request rather
than in an "options" object, the output cap is max_tokens, there is no top_k,
and reasoning arrives as delta.reasoning_content instead of message.thinking.

Endpoints implemented:
  - GET  /healthz
  - GET  /v1beta/models
  - GET  /v1beta/models/{model}
  - POST /v1beta/models/{model}:generateContent
  - POST /v1beta/models/{model}:streamGenerateContent   (JSON array, or SSE with ?alt=sse)
  - POST /v1beta/models/{model}:countTokens             (estimate: no model call)

Translated both ways: text, inline images, function declarations / calls /
responses, thinking ("thought" parts), generationConfig (temperature, topP,
topK, maxOutputTokens, stopSequences, seed, penalties, JSON mode/schema,
thinkingBudget) and usageMetadata. Content the upstream cannot take (fileData
URIs, non-image inline data, code-execution parts) is rejected with a 400
rather than silently dropped. Model names may carry tags and namespaces
(models/ns/model:tag:method); the method is split off at the last colon.

Environment: KIMO_SHIM_UPSTREAM_TOKEN, when set, is sent as
"Authorization: Bearer <token>" to the upstream (a token-protected bridge, or
the API key of a hosted provider). KIMO_SHIM_CLIENT_KEY, when set, is the key
callers must present.
"""

from __future__ import annotations

import argparse
import hmac
import json
import logging
import math
import os
import re
import signal
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="[gemini-shim] %(asctime)s - %(message)s")
logger = logging.getLogger("gemini-shim")

METHODS = ("generateContent", "streamGenerateContent", "countTokens")
UPSTREAM_KINDS = ("ollama", "openai")
MODEL_PATH = re.compile(r"^/(?:v1beta|v1)/models/(.+):(%s)$" % "|".join(METHODS))
MAX_BODY = 64 * 1024 * 1024  # inline images make requests large, but bound them
STATUS = {400: "INVALID_ARGUMENT", 401: "UNAUTHENTICATED", 403: "PERMISSION_DENIED",
          404: "NOT_FOUND", 413: "INVALID_ARGUMENT", 429: "RESOURCE_EXHAUSTED",
          500: "INTERNAL", 502: "UNAVAILABLE", 503: "UNAVAILABLE", 504: "DEADLINE_EXCEEDED"}
FINISH = {"stop": "STOP", "length": "MAX_TOKENS"}
FINISH_OPENAI = {"stop": "STOP", "length": "MAX_TOKENS", "tool_calls": "STOP",
                 "function_call": "STOP", "content_filter": "SAFETY"}


class RequestError(Exception):
    """A client error reported to the caller as a Gemini error object."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def error_body(code: int, message: str) -> dict:
    return {"error": {"code": code, "message": message, "status": STATUS.get(code, "UNKNOWN")}}


# -----------------------------------------------------------------------------
# Gemini request -> upstream request (Ollama /api/chat or OpenAI chat/completions)
# -----------------------------------------------------------------------------
def convert_schema(schema: object) -> object:
    """Gemini Schema (OBJECT/STRING... upper-case types) -> JSON Schema."""
    if isinstance(schema, list):
        return [convert_schema(item) for item in schema]
    if not isinstance(schema, dict):
        return schema
    out = {}
    for key, value in schema.items():
        if key == "type" and isinstance(value, str):
            out[key] = value.lower()
        elif key == "nullable":
            continue
        elif key == "properties" and isinstance(value, dict):
            out[key] = {name: convert_schema(prop) for name, prop in value.items()}
        elif key in ("items", "anyOf", "oneOf", "allOf"):
            out[key] = convert_schema(value)
        else:
            out[key] = value
    return out


def parts_of(holder: object, where: str) -> list:
    if not isinstance(holder, dict):
        raise RequestError(400, f"{where} must be an object.")
    parts = holder.get("parts", [])
    if not isinstance(parts, list) or not all(isinstance(p, dict) for p in parts):
        raise RequestError(400, f"{where}.parts must be a list of objects.")
    return parts


def convert_turn(turn: dict, index: int, flavor: str = "ollama",
                 pending_calls: dict | None = None) -> list:
    """One Gemini content -> one or more upstream messages.

    `flavor` picks the wire the messages are rendered for. The two disagree on
    images (a base64 array vs. data-URL content parts), on tool-call arguments
    (an object vs. a JSON string carrying a mandatory id) and on tool results
    (`tool_name` vs. `tool_call_id`). `pending_calls` maps a function name to
    the call ids already offered for it, so an OpenAI tool result can name the
    call it answers: Gemini clients routinely echo back only the name.
    """
    backend = "Ollama" if flavor == "ollama" else "OpenAI-compatible"
    role = turn.get("role", "user")
    role = {"model": "assistant", "function": "user"}.get(role, role)
    if role not in ("user", "assistant", "system"):
        raise RequestError(400, f"contents[{index}].role '{turn.get('role')}' is not supported.")
    text, images, tool_calls, tool_results = [], [], [], []
    for part in parts_of(turn, f"contents[{index}]"):
        if "text" in part:
            if part.get("thought"):
                continue  # earlier reasoning is not replayed to the model
            text.append(str(part["text"]))
        elif "inlineData" in part or "inline_data" in part:
            data = part.get("inlineData") or part.get("inline_data") or {}
            mime = data.get("mimeType") or data.get("mime_type") or ""
            if not mime.startswith("image/"):
                raise RequestError(400, f"inlineData of type '{mime or 'unknown'}' is not supported by the {backend} shim (images only).")
            images.append((mime, data.get("data", "")))
        elif "functionCall" in part or "function_call" in part:
            call = part.get("functionCall") or part.get("function_call") or {}
            name = call.get("name", "")
            tool_calls.append((str(call.get("id") or f"call_{index}_{len(tool_calls)}_{name}"),
                               name, call.get("args") or {}))
        elif "functionResponse" in part or "function_response" in part:
            result = part.get("functionResponse") or part.get("function_response") or {}
            tool_results.append((str(result.get("id") or ""), result.get("name", ""),
                                 json.dumps(result.get("response", {}))))
        elif "fileData" in part or "file_data" in part:
            raise RequestError(400, f"fileData (URI) parts are not supported by the {backend} shim; send inline data instead.")
        elif "executableCode" in part or "codeExecutionResult" in part:
            raise RequestError(400, f"Code-execution parts are not supported by the {backend} shim.")
        elif "thoughtSignature" in part or "thought_signature" in part:
            continue
        else:
            raise RequestError(400, f"Unsupported part in contents[{index}]: {', '.join(sorted(part)) or 'empty'}.")
    messages = []
    if text or images or tool_calls:
        joined = "".join(text)
        if flavor == "openai" and images:
            content = [{"type": "text", "text": joined}] if joined else []
            content += [{"type": "image_url", "image_url": {"url": f"data:{mime};base64,{blob}"}}
                        for mime, blob in images]
            message = {"role": role, "content": content}
        else:
            message = {"role": role, "content": joined}
            if images:
                message["images"] = [blob for _, blob in images]
        if tool_calls:
            if flavor == "openai":
                message["tool_calls"] = [
                    {"id": call_id, "type": "function",
                     "function": {"name": name, "arguments": json.dumps(args)}}
                    for call_id, name, args in tool_calls]
            else:
                message["tool_calls"] = [{"function": {"name": name, "arguments": args}}
                                         for _, name, args in tool_calls]
            if pending_calls is not None:
                for call_id, name, _ in tool_calls:
                    pending_calls.setdefault(name, []).append(call_id)
        messages.append(message)
    for call_id, name, body in tool_results:
        if flavor == "openai":
            if not call_id:
                offered = (pending_calls or {}).get(name) or []
                call_id = offered.pop(0) if offered else f"call_{name}"
            messages.append({"role": "tool", "tool_call_id": call_id, "content": body})
        else:
            messages.append({"role": "tool", "tool_name": name, "content": body})
    return messages


def convert_tools(request: dict) -> list:
    config = (request.get("toolConfig") or {}).get("functionCallingConfig") or {}
    if str(config.get("mode", "")).upper() == "NONE":
        return []
    tools = request.get("tools") or []
    if not isinstance(tools, list):
        raise RequestError(400, "tools must be a list.")
    out = []
    for tool in tools:
        if not isinstance(tool, dict):
            raise RequestError(400, "Each tool must be an object.")
        declarations = tool.get("functionDeclarations") or tool.get("function_declarations") or []
        for decl in declarations:
            if not isinstance(decl, dict) or not decl.get("name"):
                raise RequestError(400, "Each function declaration needs a name.")
            if "parametersJsonSchema" in decl:
                params = decl["parametersJsonSchema"]
            else:
                params = convert_schema(decl.get("parameters") or {"type": "object", "properties": {}})
            out.append({"type": "function", "function": {
                "name": decl["name"], "description": decl.get("description", ""), "parameters": params}})
        others = sorted(set(tool) - {"functionDeclarations", "function_declarations"})
        if others:
            logger.info("ignoring tools Ollama cannot provide: %s", ", ".join(others))
    return out


def build_chat(request: dict, model: str, stream: bool) -> dict:
    if not isinstance(request, dict):
        raise RequestError(400, "Request body must be a JSON object.")
    messages = []
    system = request.get("systemInstruction") or request.get("system_instruction")
    if system:
        text = "".join(str(p.get("text", "")) for p in parts_of(system, "systemInstruction"))
        if text:
            messages.append({"role": "system", "content": text})
    contents = request.get("contents", [])
    if not isinstance(contents, list):
        raise RequestError(400, "contents must be a list.")
    for index, turn in enumerate(contents):
        if not isinstance(turn, dict):
            raise RequestError(400, f"contents[{index}] must be an object.")
        messages.extend(convert_turn(turn, index))

    payload = {"model": model, "messages": messages, "stream": stream}
    tools = convert_tools(request)
    if tools:
        payload["tools"] = tools

    config = request.get("generationConfig") or {}
    if not isinstance(config, dict):
        raise RequestError(400, "generationConfig must be an object.")
    options = {}
    try:
        for src, dst, cast in (("temperature", "temperature", float), ("topP", "top_p", float),
                               ("topK", "top_k", int), ("maxOutputTokens", "num_predict", int),
                               ("seed", "seed", int), ("presencePenalty", "presence_penalty", float),
                               ("frequencyPenalty", "frequency_penalty", float)):
            if config.get(src) is not None:
                options[dst] = cast(config[src])
    except (TypeError, ValueError) as exc:
        raise RequestError(400, f"Invalid generationConfig value: {exc}") from None
    stops = config.get("stopSequences")
    if stops:
        options["stop"] = [str(s) for s in stops] if isinstance(stops, list) else [str(stops)]
    if options:
        payload["options"] = options
    schema = config.get("responseJsonSchema") or config.get("responseSchema")
    if schema:
        payload["format"] = schema if "responseJsonSchema" in config else convert_schema(schema)
    elif config.get("responseMimeType") == "application/json":
        payload["format"] = "json"
    thinking = config.get("thinkingConfig") or {}
    if isinstance(thinking, dict) and thinking.get("thinkingBudget") == 0:
        payload["think"] = False
    elif isinstance(thinking, dict) and thinking.get("includeThoughts"):
        payload["think"] = True
    return payload


def tool_choice_of(request: dict) -> str:
    """Gemini functionCallingConfig.mode -> OpenAI tool_choice, or "" to omit."""
    config = (request.get("toolConfig") or {}).get("functionCallingConfig") or {}
    return {"ANY": "required", "AUTO": "auto"}.get(str(config.get("mode", "")).upper(), "")


def build_openai_chat(request: dict, model: str, stream: bool) -> dict:
    """Gemini request -> OpenAI chat/completions payload.

    Used for a hosted OpenAI-compatible upstream (Alibaba Model Studio's
    compatible-mode surface among them), which takes sampling controls at the
    top level instead of an "options" object and caps output with max_tokens.
    """
    if not isinstance(request, dict):
        raise RequestError(400, "Request body must be a JSON object.")
    pending_calls: dict = {}
    messages = []
    system = request.get("systemInstruction") or request.get("system_instruction")
    if system:
        text = "".join(str(p.get("text", "")) for p in parts_of(system, "systemInstruction"))
        if text:
            messages.append({"role": "system", "content": text})
    contents = request.get("contents", [])
    if not isinstance(contents, list):
        raise RequestError(400, "contents must be a list.")
    for index, turn in enumerate(contents):
        if not isinstance(turn, dict):
            raise RequestError(400, f"contents[{index}] must be an object.")
        messages.extend(convert_turn(turn, index, "openai", pending_calls))

    payload = {"model": model, "messages": messages, "stream": stream}
    if stream:
        # Without this the compatible-mode stream carries no usage object at
        # all, and usageMetadata would report zero tokens for the whole turn.
        payload["stream_options"] = {"include_usage": True}

    config = request.get("generationConfig") or {}
    if not isinstance(config, dict):
        raise RequestError(400, "generationConfig must be an object.")
    try:
        for src, dst, cast in (("temperature", "temperature", float), ("topP", "top_p", float),
                               ("maxOutputTokens", "max_tokens", int), ("seed", "seed", int),
                               ("presencePenalty", "presence_penalty", float),
                               ("frequencyPenalty", "frequency_penalty", float)):
            if config.get(src) is not None:
                payload[dst] = cast(config[src])
    except (TypeError, ValueError) as exc:
        raise RequestError(400, f"Invalid generationConfig value: {exc}") from None
    if config.get("topK") is not None:
        logger.info("ignoring topK: the OpenAI-compatible wire has no such control")
    stops = config.get("stopSequences")
    if stops:
        payload["stop"] = [str(s) for s in stops] if isinstance(stops, list) else [str(stops)]

    schema = config.get("responseJsonSchema") or config.get("responseSchema")
    if schema:
        payload["response_format"] = {"type": "json_schema", "json_schema": {
            "name": "response_schema", "strict": True,
            "schema": schema if "responseJsonSchema" in config else convert_schema(schema)}}
    elif config.get("responseMimeType") == "application/json":
        payload["response_format"] = {"type": "json_object"}

    thinking = config.get("thinkingConfig") or {}
    if isinstance(thinking, dict) and thinking:
        budget = thinking.get("thinkingBudget")
        if budget == 0:
            payload["enable_thinking"] = False
        elif stream:
            # Turning thinking *on* is only forwarded when streaming: the
            # compatible-mode surface rejects enable_thinking=true on a
            # non-streaming call, and generateContent is not the path a Gemini
            # client uses for its main turn anyway.
            if thinking.get("includeThoughts") or budget is not None:
                payload["enable_thinking"] = True
            if isinstance(budget, int) and budget > 0:
                payload["thinking_budget"] = budget

    tools = convert_tools(request)
    if tools:
        payload["tools"] = tools
        choice = tool_choice_of(request)
        if choice:
            payload["tool_choice"] = choice
    return payload


def estimate_tokens(request: dict) -> int:
    """countTokens without loading the model: ~4 characters per token."""
    inner = request.get("generateContentRequest") if isinstance(request.get("generateContentRequest"), dict) else request
    chars = 0
    for turn in inner.get("contents") or []:
        for part in (turn.get("parts") or []) if isinstance(turn, dict) else []:
            if isinstance(part, dict):
                chars += len(str(part.get("text", "")))
                if "functionCall" in part or "functionResponse" in part:
                    chars += len(json.dumps(part))
    system = inner.get("systemInstruction")
    system_parts = (system.get("parts") or []) if isinstance(system, dict) else []
    for part in system_parts:
        if isinstance(part, dict):
            chars += len(str(part.get("text", "")))
    return math.ceil(chars / 4)


# -----------------------------------------------------------------------------
# Upstream response -> Gemini response
# -----------------------------------------------------------------------------
def call_part(call: dict) -> dict:
    """One upstream tool_call -> a Gemini functionCall part."""
    function = call.get("function") or {}
    args = function.get("arguments") or {}
    if isinstance(args, str):
        try:
            args = json.loads(args) if args.strip() else {}
        except ValueError:
            args = {"_raw": args}
    part = {"name": function.get("name", ""), "args": args}
    if call.get("id"):
        part["id"] = call["id"]
    return {"functionCall": part}


def to_parts(message: dict) -> list:
    parts = []
    if message.get("thinking"):
        parts.append({"text": message["thinking"], "thought": True})
    if message.get("content"):
        parts.append({"text": message["content"]})
    parts += [call_part(call) for call in message.get("tool_calls") or []]
    return parts


def to_parts_openai(message: dict) -> list:
    """An OpenAI chat message -> Gemini parts.

    Reasoning arrives as reasoning_content (what the Qwen compatible-mode
    surface returns) rather than Ollama's message.thinking.
    """
    parts = []
    if message.get("reasoning_content"):
        parts.append({"text": message["reasoning_content"], "thought": True})
    if message.get("content"):
        parts.append({"text": message["content"]})
    parts += [call_part(call) for call in message.get("tool_calls") or []]
    return parts


def usage(chunk: dict) -> dict:
    prompt, output = chunk.get("prompt_eval_count") or 0, chunk.get("eval_count") or 0
    return {"promptTokenCount": prompt, "candidatesTokenCount": output, "totalTokenCount": prompt + output}


def usage_openai(chunk: dict) -> dict:
    counts = chunk.get("usage") or {}
    prompt, output = counts.get("prompt_tokens") or 0, counts.get("completion_tokens") or 0
    return {"promptTokenCount": prompt, "candidatesTokenCount": output,
            "totalTokenCount": counts.get("total_tokens") or (prompt + output)}


def candidate(parts: list, finish: str | None) -> dict:
    cand = {"content": {"parts": parts, "role": "model"}, "index": 0}
    if finish:
        cand["finishReason"] = finish
    return cand


class GeminiShimHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002  # pylint: disable=redefined-builtin
        # Suppress routine access log noise on stdout
        pass

    def _send_json_response(self, status: int, data: dict | list) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _send_error(self, code: int, message: str) -> None:
        self._send_json_response(code, error_body(code, message))

    def _authorized(self) -> bool:
        """With a client key configured, require it as Gemini clients send it:
        the x-goog-api-key header or a ?key= query parameter. Without this any
        local process (or a web page that guesses the port) could drive the
        upstream, and with it the bridge token the shim attaches."""
        expected = self.server.client_key
        if not expected:
            return True
        given = self.headers.get("x-goog-api-key", "")
        if not given:
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            given = (query.get("key") or [""])[0]
        if hmac.compare_digest(given.encode("utf-8"), expected.encode("utf-8")):
            return True
        self._send_error(401, "Missing or invalid API key for this shim.")
        return False

    def _model_entry(self, name: str) -> dict:
        return {"name": f"models/{name}", "displayName": name, "supportedGenerationMethods": list(METHODS)}

    def _upstream(self, path: str, payload: dict | None = None, timeout: float = 300.0):
        url = self.server.upstream.rstrip("/") + path
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {"Content-Type": "application/json", "User-Agent": "kimo-gemini-shim"}
        if self.server.upstream_auth:
            headers["Authorization"] = self.server.upstream_auth
        req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET", headers=headers)
        # Scheme checked to be http(s) in GeminiShimServer.__init__.
        return urllib.request.urlopen(req, timeout=timeout)  # nosec B310

    def _upstream_models(self) -> list:
        """The upstream catalogue, or the default model when it cannot answer."""
        try:
            if self.server.upstream_kind == "openai":
                with self._upstream("/models", timeout=10.0) as resp:
                    raw = json.loads(resp.read().decode("utf-8"))
                return [m.get("id", "") for m in raw.get("data", []) if isinstance(m, dict)]
            with self._upstream("/api/tags", timeout=5.0) as resp:
                raw = json.loads(resp.read().decode("utf-8"))
            return [m.get("name", "") for m in raw.get("models", [])]
        except Exception:
            # Upstream error or offline: advertise the default so the client's
            # model picker is not empty.
            return [self.server.default_model or "kalidroid-27b:latest"]

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path

        if path in ("/healthz", "/health"):
            self._send_json_response(200, {"status": "ok", "service": "ollama-gemini-shim"})
            return
        if not self._authorized():
            return

        if path in ("/v1beta/models", "/v1/models"):
            self._send_json_response(200, {"models": [self._model_entry(n) for n in self._upstream_models()]})
            return

        match = re.match(r"^/(?:v1beta|v1)/models/(.+)$", path)
        if match:
            self._send_json_response(200, self._model_entry(urllib.parse.unquote(match.group(1))))
            return

        self._send_error(404, f"Endpoint '{path}' not found.")

    def _read_body(self) -> dict:
        raw_length = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(raw_length)
        except ValueError:
            raise RequestError(400, f"Invalid Content-Length '{raw_length}'.") from None
        if length < 0:
            raise RequestError(400, "Invalid Content-Length.")
        if length > MAX_BODY:
            raise RequestError(413, f"Request body exceeds {MAX_BODY // (1024 * 1024)} MiB.")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise RequestError(400, f"Invalid JSON payload: {exc}") from None
        if not isinstance(body, dict):
            raise RequestError(400, "Request body must be a JSON object.")
        return body

    def do_POST(self) -> None:
        if not self._authorized():
            return
        parsed = urllib.parse.urlparse(self.path)
        match = MODEL_PATH.match(parsed.path)
        if not match:
            self._send_error(404, f"Unsupported path '{parsed.path}'.")
            return
        model = urllib.parse.unquote(match.group(1))
        model = model.removeprefix("models/") or self.server.default_model
        method = match.group(2)

        try:
            request = self._read_body()
            if method == "countTokens":
                self._send_json_response(200, {"totalTokens": estimate_tokens(request)})
                return
            stream = method == "streamGenerateContent"
            if self.server.upstream_kind == "openai":
                payload, path = build_openai_chat(request, model, stream), "/chat/completions"
            else:
                payload, path = build_chat(request, model, stream), "/api/chat"
        except RequestError as exc:
            self._send_error(exc.code, exc.message)
            return

        try:
            resp = self._upstream(path, payload)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            e.close()
            try:
                detail = json.loads(body).get("error", body)
                body = detail.get("message") or json.dumps(detail) if isinstance(detail, dict) else detail
            except (ValueError, AttributeError):
                pass
            self._send_error(e.code, str(body or e.reason))
            return
        except Exception as e:
            self._send_error(502, f"Upstream connect failed: {e}")
            return

        with resp:
            if stream:
                self._stream(resp, model, parsed,
                             self._relay_openai if self.server.upstream_kind == "openai" else self._relay_ollama)
            elif self.server.upstream_kind == "openai":
                self._complete_openai(resp, model)
            else:
                self._complete(resp, model)

    def _complete(self, resp, model: str) -> None:
        try:
            raw = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            self._send_error(502, f"Failed reading upstream response: {e}")
            return
        if raw.get("error"):
            self._send_error(502, f"Upstream error: {raw['error']}")
            return
        parts = to_parts(raw.get("message") or {}) or [{"text": ""}]
        self._send_json_response(200, {
            "candidates": [candidate(parts, FINISH.get(raw.get("done_reason"), "STOP"))],
            "usageMetadata": usage(raw),
            "modelVersion": model,
        })

    def _complete_openai(self, resp, model: str) -> None:
        try:
            raw = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            self._send_error(502, f"Failed reading upstream response: {e}")
            return
        if raw.get("error"):
            self._send_error(502, f"Upstream error: {raw['error']}")
            return
        choices = raw.get("choices") or [{}]
        parts = to_parts_openai(choices[0].get("message") or {}) or [{"text": ""}]
        # modelVersion echoes the requested id: the upstream may answer with a
        # dated snapshot name the client has never registered.
        self._send_json_response(200, {
            "candidates": [candidate(parts, FINISH_OPENAI.get(choices[0].get("finish_reason"), "STOP"))],
            "usageMetadata": usage_openai(raw),
            "modelVersion": model,
        })

    def _relay_ollama(self, resp, model: str, emit) -> None:
        """Read an NDJSON /api/chat stream and emit one Gemini object per chunk."""
        finished = False
        for raw_line in resp:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                chunk = json.loads(line)
            except ValueError:
                continue
            if not isinstance(chunk, dict):
                continue
            if chunk.get("error"):
                emit(error_body(500, f"Upstream error: {chunk['error']}"))
                return
            parts = to_parts(chunk.get("message") or {})
            if chunk.get("done"):
                emit({"candidates": [candidate(parts or [{"text": ""}], FINISH.get(chunk.get("done_reason"), "STOP"))],
                      "usageMetadata": usage(chunk), "modelVersion": model})
                finished = True
                break
            if parts:
                emit({"candidates": [candidate(parts, None)], "modelVersion": model})
        if not finished:
            emit(error_body(502, "Upstream stream ended before completion."))

    def _relay_openai(self, resp, model: str, emit) -> None:
        """Read an SSE chat/completions stream and emit Gemini objects.

        Text and reasoning deltas pass through as they arrive. Tool-call
        arguments are fragmented across chunks and only mean something once
        complete, so they are accumulated by index and emitted with the final
        candidate.
        """
        calls: dict = {}
        finish, usage_chunk, done = "", {}, False
        for raw_line in resp:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            if not isinstance(chunk, dict):
                continue
            if chunk.get("error"):
                emit(error_body(500, f"Upstream error: {chunk['error']}"))
                return
            if chunk.get("usage"):
                usage_chunk = chunk
            for choice in chunk.get("choices") or []:
                if not isinstance(choice, dict):
                    continue
                delta = choice.get("delta") or {}
                parts = []
                if delta.get("reasoning_content"):
                    parts.append({"text": delta["reasoning_content"], "thought": True})
                if delta.get("content"):
                    parts.append({"text": delta["content"]})
                for call in delta.get("tool_calls") or []:
                    slot = calls.setdefault(call.get("index") or 0,
                                            {"id": "", "function": {"name": "", "arguments": ""}})
                    if call.get("id"):
                        slot["id"] = call["id"]
                    function = call.get("function") or {}
                    if function.get("name"):
                        slot["function"]["name"] = function["name"]
                    if function.get("arguments"):
                        slot["function"]["arguments"] += function["arguments"]
                if parts:
                    emit({"candidates": [candidate(parts, None)], "modelVersion": model})
                if choice.get("finish_reason"):
                    finish = choice["finish_reason"]
        if not (finish or done):
            emit(error_body(502, "Upstream stream ended before completion."))
            return
        final = [call_part(calls[index]) for index in sorted(calls)] or [{"text": ""}]
        emit({"candidates": [candidate(final, FINISH_OPENAI.get(finish, "STOP"))],
              "usageMetadata": usage_openai(usage_chunk), "modelVersion": model})

    def _stream(self, resp, model: str, parsed, relay) -> None:
        """Frame a Gemini stream, whichever upstream wire `relay` reads.

        `relay(resp, model, emit)` parses the upstream stream and calls `emit`
        once per Gemini object, ending with exactly one terminal object (a
        candidate carrying finishReason, or an error body). The framing the
        client asked for - SSE with ?alt=sse, otherwise one JSON array written
        piecewise - is applied here so both relays share it.
        """
        query = urllib.parse.parse_qs(parsed.query)
        use_sse = "sse" in query.get("alt", []) or "text/event-stream" in self.headers.get("Accept", "")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8" if use_sse else "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        first = True

        def emit(obj: dict) -> None:
            nonlocal first
            data = json.dumps(obj)
            if use_sse:
                self.wfile.write(f"data: {data}\n\n".encode())
            else:
                # The REST (non-SSE) stream is one JSON array, written piecewise.
                self.wfile.write((("[" if first else ",\r\n") + data).encode())
            first = False
            self.wfile.flush()

        try:
            relay(resp, model, emit)
            if not use_sse:
                self.wfile.write(b"[]" if first else b"]")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class GeminiShimServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], upstream: str, default_model: str,
                 upstream_token: str = "", client_key: str = "",  # nosec B107 - empty means no auth
                 upstream_kind: str = "ollama"):
        # The upstream is opened with urllib, which would also follow file:// or
        # custom schemes; only an HTTP(S) endpoint is acceptable.
        if urllib.parse.urlparse(upstream).scheme not in ("http", "https"):
            raise ValueError(f"--upstream must be an http(s) URL, got '{upstream}'")
        if upstream_kind not in UPSTREAM_KINDS:
            raise ValueError(f"--upstream-kind must be one of {'/'.join(UPSTREAM_KINDS)}, got '{upstream_kind}'")
        super().__init__(server_address, GeminiShimHandler)
        self.upstream = upstream
        self.upstream_kind = upstream_kind
        self.default_model = default_model
        # Bearer token for the upstream: a token-protected bridge in front of
        # Ollama, or the API key of a hosted provider. It comes from the
        # environment, never argv, and goes only to the upstream.
        self.upstream_auth = f"Bearer {upstream_token}" if upstream_token else ""
        # Key clients must present (see GeminiShimHandler._authorized); also
        # from the environment only. Empty leaves the shim open, as before.
        self.client_key = client_key


def main() -> None:
    parser = argparse.ArgumentParser(description="Gemini wire-format translation shim")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host address")
    parser.add_argument("--port", type=int, default=0, help="Bind port (0 for dynamic)")
    parser.add_argument("--upstream", default="http://127.0.0.1:11434", help="Upstream base URL")
    parser.add_argument("--upstream-kind", default="ollama", choices=UPSTREAM_KINDS,
                        help="Wire the upstream speaks: ollama (/api/chat) or openai (/chat/completions)")
    parser.add_argument("--default-model", default="kalidroid-27b:latest", help="Default target model")
    parser.add_argument("--print-port", action="store_true", help="Print bound port to stdout")
    args = parser.parse_args()

    try:
        server = GeminiShimServer((args.host, args.port), args.upstream, args.default_model,
                                  os.environ.get("KIMO_SHIM_UPSTREAM_TOKEN", ""),
                                  client_key=os.environ.get("KIMO_SHIM_CLIENT_KEY", ""),
                                  upstream_kind=args.upstream_kind)
    except ValueError as exc:
        parser.error(str(exc))
    bound_port = server.server_address[1]

    if args.print_port:
        sys.stdout.write(f"{bound_port}\n")
        sys.stdout.flush()

    def shutdown_signal(sig: int, frame: object) -> None:
        threading.Thread(target=server.shutdown).start()

    signal.signal(signal.SIGINT, shutdown_signal)
    signal.signal(signal.SIGTERM, shutdown_signal)

    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
