#!/usr/bin/env python3
"""
ollama-gemini-shim.py – Gemini wire-format to Ollama /api/chat translation shim.

Enables Google Antigravity (agy) and other Gemini-only CLI clients to seamlessly
interface with native and remote Ollama instances without external proxies.

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
thinkingBudget) and usageMetadata. Content Ollama cannot take (fileData
URIs, non-image inline data, code-execution parts) is rejected with a 400
rather than silently dropped. Model names may carry tags and namespaces
(models/ns/model:tag:method); the method is split off at the last colon.

Environment: KIMO_SHIM_UPSTREAM_TOKEN, when set, is sent as
"Authorization: Bearer <token>" to the upstream (a token-protected bridge).
"""

from __future__ import annotations

import argparse
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
MODEL_PATH = re.compile(r"^/(?:v1beta|v1)/models/(.+):(%s)$" % "|".join(METHODS))
MAX_BODY = 64 * 1024 * 1024  # inline images make requests large, but bound them
STATUS = {400: "INVALID_ARGUMENT", 401: "UNAUTHENTICATED", 403: "PERMISSION_DENIED",
          404: "NOT_FOUND", 413: "INVALID_ARGUMENT", 429: "RESOURCE_EXHAUSTED",
          500: "INTERNAL", 502: "UNAVAILABLE", 503: "UNAVAILABLE", 504: "DEADLINE_EXCEEDED"}
FINISH = {"stop": "STOP", "length": "MAX_TOKENS"}


class RequestError(Exception):
    """A client error reported to the caller as a Gemini error object."""

    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def error_body(code: int, message: str) -> dict:
    return {"error": {"code": code, "message": message, "status": STATUS.get(code, "UNKNOWN")}}


# -----------------------------------------------------------------------------
# Gemini request -> Ollama /api/chat
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


def convert_turn(turn: dict, index: int) -> list:
    """One Gemini content -> one or more Ollama messages."""
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
                raise RequestError(400, f"inlineData of type '{mime or 'unknown'}' is not supported by the Ollama shim (images only).")
            images.append(data.get("data", ""))
        elif "functionCall" in part or "function_call" in part:
            call = part.get("functionCall") or part.get("function_call") or {}
            tool_calls.append({"function": {"name": call.get("name", ""), "arguments": call.get("args") or {}}})
        elif "functionResponse" in part or "function_response" in part:
            result = part.get("functionResponse") or part.get("function_response") or {}
            tool_results.append({"role": "tool", "tool_name": result.get("name", ""),
                                 "content": json.dumps(result.get("response", {}))})
        elif "fileData" in part or "file_data" in part:
            raise RequestError(400, "fileData (URI) parts are not supported by the Ollama shim; send inline data instead.")
        elif "executableCode" in part or "codeExecutionResult" in part:
            raise RequestError(400, "Code-execution parts are not supported by the Ollama shim.")
        elif "thoughtSignature" in part or "thought_signature" in part:
            continue
        else:
            raise RequestError(400, f"Unsupported part in contents[{index}]: {', '.join(sorted(part)) or 'empty'}.")
    messages = []
    if text or images or tool_calls:
        message = {"role": role, "content": "".join(text)}
        if images:
            message["images"] = images
        if tool_calls:
            message["tool_calls"] = tool_calls
        messages.append(message)
    messages.extend(tool_results)
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
# Ollama /api/chat -> Gemini response
# -----------------------------------------------------------------------------
def to_parts(message: dict) -> list:
    parts = []
    if message.get("thinking"):
        parts.append({"text": message["thinking"], "thought": True})
    if message.get("content"):
        parts.append({"text": message["content"]})
    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        args = function.get("arguments") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                args = {"_raw": args}
        call_part = {"name": function.get("name", ""), "args": args}
        if call.get("id"):
            call_part["id"] = call["id"]
        parts.append({"functionCall": call_part})
    return parts


def usage(chunk: dict) -> dict:
    prompt, output = chunk.get("prompt_eval_count") or 0, chunk.get("eval_count") or 0
    return {"promptTokenCount": prompt, "candidatesTokenCount": output, "totalTokenCount": prompt + output}


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

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path

        if path in ("/healthz", "/health"):
            self._send_json_response(200, {"status": "ok", "service": "ollama-gemini-shim"})
            return

        if path in ("/v1beta/models", "/v1/models"):
            try:
                with self._upstream("/api/tags", timeout=5.0) as resp:
                    raw = json.loads(resp.read().decode("utf-8"))
                names = [m.get("name", "") for m in raw.get("models", [])]
            except Exception:
                # Upstream error or offline: return default model
                names = [self.server.default_model or "kalidroid-27b:latest"]
            self._send_json_response(200, {"models": [self._model_entry(n) for n in names]})
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
            payload = build_chat(request, model, stream)
        except RequestError as exc:
            self._send_error(exc.code, exc.message)
            return

        try:
            resp = self._upstream("/api/chat", payload)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            e.close()
            try:
                body = json.loads(body).get("error", body)
            except (ValueError, AttributeError):
                pass
            self._send_error(e.code, str(body or e.reason))
            return
        except Exception as e:
            self._send_error(502, f"Upstream connect failed: {e}")
            return

        with resp:
            if stream:
                self._stream(resp, model, parsed)
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

    def _stream(self, resp, model: str, parsed) -> None:
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
                    finished = True
                    break
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
            if not use_sse:
                self.wfile.write(b"[]" if first else b"]")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class GeminiShimServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address: tuple[str, int], upstream: str, default_model: str,
                 upstream_token: str = ""):  # nosec B107 - empty means no upstream auth
        # The upstream is opened with urllib, which would also follow file:// or
        # custom schemes; only an Ollama HTTP(S) endpoint is acceptable.
        if urllib.parse.urlparse(upstream).scheme not in ("http", "https"):
            raise ValueError(f"--upstream must be an http(s) URL, got '{upstream}'")
        super().__init__(server_address, GeminiShimHandler)
        self.upstream = upstream
        self.default_model = default_model
        # Bearer token for a token-protected bridge in front of Ollama. It comes
        # from the environment, never argv, and goes only to the upstream.
        self.upstream_auth = f"Bearer {upstream_token}" if upstream_token else ""


def main() -> None:
    parser = argparse.ArgumentParser(description="Ollama Gemini Translation Shim")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host address")
    parser.add_argument("--port", type=int, default=0, help="Bind port (0 for dynamic)")
    parser.add_argument("--upstream", default="http://127.0.0.1:11434", help="Upstream Ollama URL")
    parser.add_argument("--default-model", default="kalidroid-27b:latest", help="Default target model")
    parser.add_argument("--print-port", action="store_true", help="Print bound port to stdout")
    args = parser.parse_args()

    try:
        server = GeminiShimServer((args.host, args.port), args.upstream, args.default_model,
                                  os.environ.get("KIMO_SHIM_UPSTREAM_TOKEN", ""))
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
