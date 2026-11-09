#!/usr/bin/env python3
"""
ollama-gemini-shim.py – Gemini wire-format translation shim.

Enables Google Antigravity (agy) and other Gemini-only CLI clients to seamlessly
interface with native and remote Ollama instances without external proxies.

Three upstream wires, picked with --upstream-kind:
  - ollama (default)  {upstream}/api/chat, NDJSON stream, {upstream}/api/tags
  - openai            {upstream}/chat/completions, SSE stream, {upstream}/models
  - responses         {upstream}/responses, SSE stream
The openai kind is what reaches a hosted OpenAI-compatible API such as Alibaba
Model Studio's compatible-mode surface, which has no Gemini endpoint and no
/api/chat. Its sampling controls sit at the top level of the request rather
than in an "options" object, the output cap is max_tokens, there is no top_k,
and reasoning arrives as delta.reasoning_content instead of message.thinking.
The responses kind is the ChatGPT Codex route
({CODEX_BACKEND}/responses, no /v1 and no /chat/completions). KIMO_SHIM_CODEX=1
adds the headers and body that route accepts; without it the same kind is a
plain Responses translation and does not pretend to be the Codex CLI.

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
import base64
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
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="[gemini-shim] %(asctime)s - %(message)s")
logger = logging.getLogger("gemini-shim")

METHODS = ("generateContent", "streamGenerateContent", "countTokens")
UPSTREAM_KINDS = ("ollama", "openai", "responses")
CODEX_VERSION_DEFAULT = "0.167.0"
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


def convert_tools(request: dict, shape: str = "chat") -> list:
    """Gemini functionDeclarations -> chat (`function` nested) or Responses tools.

    Responses tools are flat: type, name, description, parameters. Nesting them
    the way chat/completions does is a 400 on the Codex route.
    """
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
            entry = {"name": decl["name"], "description": decl.get("description", ""), "parameters": params}
            if shape == "responses":
                out.append({"type": "function", **entry})
            else:
                out.append({"type": "function", "function": entry})
        others = sorted(set(tool) - {"functionDeclarations", "function_declarations"})
        if others:
            logger.info("ignoring tools the upstream cannot provide: %s", ", ".join(others))
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


def tool_choice_of(request: dict, flavor: str = "openai"):
    """Gemini functionCallingConfig.mode -> tool_choice, or "" to omit.

    A Responses ANY call that names one function becomes that function. Several
    names, or none, stay "required": the model must call a tool, and the
    declarations already say which ones exist.
    """
    config = (request.get("toolConfig") or {}).get("functionCallingConfig") or {}
    mode = str(config.get("mode", "")).upper()
    if flavor == "responses" and mode == "ANY":
        names = config.get("allowedFunctionNames") or config.get("allowed_function_names") or []
        if isinstance(names, list) and len(names) == 1 and isinstance(names[0], str) and names[0]:
            return {"type": "function", "name": names[0]}
    return {"ANY": "required", "AUTO": "auto"}.get(mode, "")


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


def _fold_model(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def match_catalog(catalog: list, model: str) -> dict | None:
    """Catalog row for a slug or a display name such as 'GPT-6.1 Terra'."""
    folded = _fold_model(model)
    lower = model.lower()
    for item in catalog:
        if not isinstance(item, dict):
            continue
        slug = item.get("slug") if isinstance(item.get("slug"), str) else ""
        if slug and (slug.lower() == lower or _fold_model(slug) == folded):
            return item
        display = item.get("display_name") if isinstance(item.get("display_name"), str) else ""
        if display and (display.lower() == lower or _fold_model(display) == folded):
            return item
    return None


def jwt_account(token: str) -> str:
    """ChatGPT account id from a Codex OAuth JWT, or "" when it is not one.

    A fixture token that is not a JWT must not raise: the header is simply
    omitted. The claim the Codex CLI sends is
    https://api.openai.com/auth -> chatgpt_account_id.
    """
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


def codex_headers(token: str, model: str, *, version: str, session_id: str, lite: bool) -> dict:
    """Headers the ChatGPT Codex HTTP client sends on /responses.

    OpenAI-Beta must be responses=experimental. responses=v1 is answered with
    an HTML 404, and a residency header of no_constraint 404s the same way.
    The websocket beta is not sent on this HTTP call. The lite header is sent
    only when the catalog row says use_responses_lite: a non-lite model 400s
    if it is present.
    """
    version = version or CODEX_VERSION_DEFAULT
    session = session_id or "kimo"
    headers = {
        "Accept": "text/event-stream",
        "OpenAI-Beta": os.environ.get("KIMO_CODEX_OPENAI_BETA", "responses=experimental"),
        "originator": os.environ.get("KIMO_CODEX_ORIGINATOR", "codex_cli_rs"),
        "version": version,
        "session_id": session,
        "session-id": session,
        "User-Agent": f"codex_cli_rs/{version}",
    }
    if model:
        headers["x-codex-routing-hint"] = f"model={model}"
    account = jwt_account(token)
    if account:
        headers["Chatgpt-Account-Id"] = account
    if lite:
        headers["x-openai-internal-codex-responses-lite"] = "true"
    return headers


def load_codex_meta() -> tuple[list, str]:
    """Catalog rows and client_version from $CODEX_HOME/models_cache.json.

    Missing or unreadable caches return an empty catalog. The launched slug
    is still advertised from --default-model, and the request still carries
    the fields the route requires.
    """
    version = CODEX_VERSION_DEFAULT
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    path = os.path.join(home, "models_cache.json")
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return [], version
    if not isinstance(data, dict):
        return [], version
    raw_version = data.get("client_version")
    if isinstance(raw_version, str) and raw_version:
        version = raw_version
    rows = []
    models = data.get("models")
    if not isinstance(models, list):
        return rows, version
    for item in models:
        if not isinstance(item, dict) or item.get("visibility", "list") != "list":
            continue
        slug = item.get("slug")
        if not isinstance(slug, str) or not slug:
            continue
        row = {"slug": slug}
        name = item.get("display_name")
        if isinstance(name, str) and name:
            row["display_name"] = name
        level = item.get("default_reasoning_level")
        if isinstance(level, str) and level:
            row["default_reasoning_level"] = level
        if item.get("use_responses_lite") is True:
            row["use_responses_lite"] = True
        rows.append(row)
    return rows, version


def _instruction_text(holder: object, where: str) -> str:
    if not holder:
        return ""
    return "".join(str(part.get("text", "")) for part in parts_of(holder, where) if not part.get("thought"))


def convert_turn_responses(turn: dict, index: int, pending_calls: dict) -> list:
    """One Gemini content -> Responses input items.

    Codex rejects role=system (that text belongs in `instructions`). Tool
    results are function_call_output items, not role=tool messages, and a
    call's arguments are a JSON string. Images are input_image data URLs.
    """
    role = turn.get("role", "user")
    role = {"model": "assistant", "function": "user"}.get(role, role)
    if role not in ("user", "assistant"):
        raise RequestError(400, f"contents[{index}].role '{turn.get('role')}' is not supported.")
    text, images, tool_calls, tool_results = [], [], [], []
    for part in parts_of(turn, f"contents[{index}]"):
        if "text" in part:
            if part.get("thought"):
                continue
            text.append(str(part["text"]))
        elif "inlineData" in part or "inline_data" in part:
            if role != "user":
                raise RequestError(400, "Images on an assistant turn are not supported by the Responses shim.")
            data = part.get("inlineData") or part.get("inline_data") or {}
            mime = data.get("mimeType") or data.get("mime_type") or ""
            if not mime.startswith("image/"):
                raise RequestError(400, f"inlineData of type '{mime or 'unknown'}' is not supported by the Responses shim (images only).")
            images.append((mime, data.get("data", "")))
        elif "functionCall" in part or "function_call" in part:
            call = part.get("functionCall") or part.get("function_call") or {}
            name = str(call.get("name") or "")
            call_id = str(call.get("id") or f"call_{index}_{len(tool_calls)}_{name}")
            args = call.get("args") if call.get("args") is not None else {}
            if not isinstance(args, str):
                args = json.dumps(args)
            tool_calls.append((call_id, name, args))
            pending_calls.setdefault(name, []).append(call_id)
        elif "functionResponse" in part or "function_response" in part:
            result = part.get("functionResponse") or part.get("function_response") or {}
            tool_results.append((str(result.get("id") or ""), str(result.get("name") or ""),
                                 json.dumps(result.get("response", {}))))
        elif "fileData" in part or "file_data" in part:
            raise RequestError(400, "fileData (URI) parts are not supported by the Responses shim; send inline data instead.")
        elif "executableCode" in part or "codeExecutionResult" in part:
            raise RequestError(400, "Code-execution parts are not supported by the Responses shim.")
        elif "thoughtSignature" in part or "thought_signature" in part:
            continue
        else:
            raise RequestError(400, f"Unsupported part in contents[{index}]: {', '.join(sorted(part)) or 'empty'}.")
    items = []
    for call_id, name, body in tool_results:
        if not call_id:
            offered = pending_calls.get(name) or []
            call_id = offered.pop(0) if offered else f"call_{name}"
        items.append({"type": "function_call_output", "call_id": call_id, "output": body})
    joined = "".join(text)
    if joined or images:
        kind = "output_text" if role == "assistant" else "input_text"
        parts = [{"type": kind, "text": joined}] if joined else []
        parts += [{"type": "input_image", "image_url": f"data:{mime};base64,{blob}"} for mime, blob in images]
        items.append({"type": "message", "role": role, "content": parts})
    for call_id, name, args in tool_calls:
        items.append({"type": "function_call", "call_id": call_id, "name": name, "arguments": args})
    return items


def build_responses(request: dict, model: str, stream: bool, *,
                    codex: bool = False, catalog: list | None = None) -> tuple[dict, bool]:
    """Gemini request -> Responses payload. Returns (body, lite).

    `lite` is true only when this is the ChatGPT Codex route and the catalog
    row sets use_responses_lite. The caller uses it for the matching header
    and must not send that header otherwise.

    Codex rejects stream=false, a missing instructions field, and a body
    without reasoning.encrypted_content. Those are filled here. Reasoning
    effort is the catalog row's own default, not a translation of the
    client's thinking budget.
    """
    if not isinstance(request, dict):
        raise RequestError(400, "Request body must be a JSON object.")
    row = match_catalog(catalog or [], model) if codex else None
    wire = row["slug"] if row else model
    lite = bool(row and row.get("use_responses_lite") is True) if codex else False

    instructions = []
    system = request.get("systemInstruction") or request.get("system_instruction")
    if system:
        instructions.append(_instruction_text(system, "systemInstruction"))
    contents = request.get("contents", [])
    if not isinstance(contents, list):
        raise RequestError(400, "contents must be a list.")
    pending: dict = {}
    items = []
    for index, turn in enumerate(contents):
        if not isinstance(turn, dict):
            raise RequestError(400, f"contents[{index}] must be an object.")
        if turn.get("role") == "system":
            instructions.append(_instruction_text(turn, f"contents[{index}]"))
            continue
        items.extend(convert_turn_responses(turn, index, pending))
    if not items:
        items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Hello"}]}]

    text = "\n".join(piece for piece in instructions if piece and piece.strip())
    if codex and not text.strip():
        text = "You are a coding assistant."
    payload = {
        "model": wire,
        "input": items,
        "stream": True if codex else stream,
        "store": False,
    }
    if text:
        payload["instructions"] = text
    if codex:
        payload["include"] = ["reasoning.encrypted_content"]
        effort = row.get("default_reasoning_level") if row else ""
        if isinstance(effort, str) and effort:
            payload["reasoning"] = {"effort": effort, "summary": "auto"}
        if lite:
            reasoning = payload.get("reasoning")
            if not isinstance(reasoning, dict):
                reasoning = {}
                payload["reasoning"] = reasoning
            reasoning.setdefault("context", "all_turns")
            payload["parallel_tool_calls"] = False

    config = request.get("generationConfig") or {}
    if not isinstance(config, dict):
        raise RequestError(400, "generationConfig must be an object.")
    try:
        if config.get("maxOutputTokens") is not None:
            cap = int(config["maxOutputTokens"])
            if cap > 0:
                payload["max_output_tokens"] = cap
        for src, dst in (("temperature", "temperature"), ("topP", "top_p")):
            if config.get(src) is not None:
                payload[dst] = float(config[src])
    except (TypeError, ValueError) as exc:
        raise RequestError(400, f"Invalid generationConfig value: {exc}") from None
    if config.get("topK") is not None:
        logger.info("ignoring topK: the Responses wire has no such control")
    if config.get("stopSequences") or config.get("responseSchema") or config.get("responseJsonSchema"):
        logger.info("ignoring stop/schema controls: the Responses translation does not forward them")

    tools = convert_tools(request, "responses")
    if tools:
        payload["tools"] = tools
        choice = tool_choice_of(request, "responses")
        if choice:
            payload["tool_choice"] = choice
    return payload, lite


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


def usage_responses(payload: dict) -> dict:
    counts = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    if not counts:
        return {}
    prompt = counts.get("input_tokens") or counts.get("prompt_tokens") or 0
    output = counts.get("output_tokens") or counts.get("completion_tokens") or 0
    total = counts.get("total_tokens")
    if not isinstance(total, int) or isinstance(total, bool):
        total = (prompt or 0) + (output or 0)
    return {"promptTokenCount": prompt or 0, "candidatesTokenCount": output or 0, "totalTokenCount": total}


def _responses_error(event: dict) -> str:
    error = event.get("error") if isinstance(event.get("error"), dict) else {}
    response = event.get("response") if isinstance(event.get("response"), dict) else {}
    nested = response.get("error") if isinstance(response.get("error"), dict) else {}
    message = error.get("message") or nested.get("message") or event.get("message") or "upstream response failed"
    return message if isinstance(message, str) else "upstream response failed"


class ResponsesAccum:
    """Fold Responses SSE events into Gemini parts.

    Text and reasoning deltas are streamed as they arrive. Function-call
    arguments are fragments, so they are held until the terminal event.
    A server that sends only the completed response (no deltas) still yields
    its output items.
    """

    def __init__(self) -> None:
        self.text: list[str] = []
        self.thought: list[str] = []
        self.calls: dict = {}
        self.finish = "STOP"
        self.usage: dict = {}
        self.error = ""
        self.done = False

    def feed(self, event: dict) -> list:
        kind = event.get("type") if isinstance(event.get("type"), str) else ""
        if kind in ("response.output_text.delta", "response.refusal.delta"):
            piece = event.get("delta")
            if isinstance(piece, str) and piece:
                self.text.append(piece)
                return [{"text": piece}]
            return []
        if kind in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta"):
            piece = event.get("delta")
            if isinstance(piece, str) and piece:
                self.thought.append(piece)
                return [{"text": piece, "thought": True}]
            return []
        if kind in ("response.output_item.added", "response.output_item.done"):
            self._note_call(event.get("output_index", 0), event.get("item"))
            return []
        if kind == "response.function_call_arguments.delta":
            self._append_args(event.get("output_index", 0), event.get("delta"))
            return []
        if kind in ("response.completed", "response.incomplete"):
            response = event.get("response") if isinstance(event.get("response"), dict) else {}
            self.usage = usage_responses(response)
            incomplete = response.get("status") == "incomplete" or kind == "response.incomplete"
            self.finish = "MAX_TOKENS" if incomplete else "STOP"
            self.done = True
            if not self.text and not self.thought and not self.calls:
                self._absorb_output(response.get("output"))
            return []
        if kind in ("response.failed", "error"):
            self.error = _responses_error(event)
            self.done = True
            return []
        if kind == "_kimo_done":
            self.done = True
            return []
        return []

    def _slot(self, index: object) -> dict:
        key = 0
        if isinstance(index, int) and not isinstance(index, bool):
            key = index
        elif isinstance(index, str) and index.lstrip("-").isdigit():
            key = int(index)
        return self.calls.setdefault(key, {"id": "", "function": {"name": "", "arguments": ""}})

    def _note_call(self, index: object, item: object) -> None:
        if not isinstance(item, dict) or item.get("type") != "function_call":
            return
        slot = self._slot(index)
        call_id = item.get("call_id") or item.get("id") or ""
        if isinstance(call_id, str) and call_id:
            slot["id"] = call_id
        name = item.get("name") or ""
        if isinstance(name, str) and name:
            slot["function"]["name"] = name
        arguments = item.get("arguments")
        if isinstance(arguments, str) and arguments and not slot["function"]["arguments"]:
            slot["function"]["arguments"] = arguments

    def _append_args(self, index: object, piece: object) -> None:
        if not isinstance(piece, str) or not piece:
            return
        self._slot(index)["function"]["arguments"] += piece

    def _absorb_output(self, output: object) -> None:
        if not isinstance(output, list):
            return
        for index, item in enumerate(output):
            if not isinstance(item, dict):
                continue
            if item.get("type") == "message":
                for part in item.get("content") or []:
                    if not isinstance(part, dict):
                        continue
                    text = part.get("text") or part.get("refusal") or ""
                    if isinstance(text, str) and text:
                        self.text.append(text)
            elif item.get("type") == "reasoning":
                for part in item.get("summary") or []:
                    if isinstance(part, dict) and isinstance(part.get("text"), str) and part["text"]:
                        self.thought.append(part["text"])
            elif item.get("type") == "function_call":
                self._note_call(index, item)

    def call_parts(self) -> list:
        return [call_part(self.calls[index]) for index in sorted(self.calls)]

    def _object(self, parts: list, model: str) -> dict:
        body = {"candidates": [candidate(parts, self.finish)], "modelVersion": model}
        if self.usage:
            body["usageMetadata"] = self.usage
        return body

    def folded(self, model: str) -> dict:
        """One Gemini object for a client that did not ask to stream."""
        parts = []
        thought = "".join(self.thought)
        text = "".join(self.text)
        if thought:
            parts.append({"text": thought, "thought": True})
        if text:
            parts.append({"text": text})
        parts += self.call_parts()
        return self._object(parts or [{"text": ""}], model)

    def terminal(self, model: str) -> dict:
        """The closing streamed candidate: tool calls, or an empty text part."""
        return self._object(self.call_parts() or [{"text": ""}], model)


def iter_sse_events(lines):
    """Yield JSON objects from SSE lines. Stops at EOF or a chat [DONE]."""
    for raw_line in lines:
        line = raw_line.decode("utf-8", "replace").strip() if isinstance(raw_line, bytes) else str(raw_line).strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data:
            continue
        if data == "[DONE]":
            yield {"type": "_kimo_done"}
            break
        try:
            event = json.loads(data)
        except ValueError:
            continue
        if isinstance(event, dict):
            yield event


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

    def _upstream(self, path: str, payload: dict | None = None, timeout: float = 300.0,
                  extra_headers: dict | None = None):
        url = self.server.upstream.rstrip("/") + path
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {"Content-Type": "application/json", "User-Agent": "kimo-gemini-shim"}
        if self.server.upstream_auth:
            headers["Authorization"] = self.server.upstream_auth
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET", headers=headers)
        # Scheme checked to be http(s) in GeminiShimServer.__init__.
        return urllib.request.urlopen(req, timeout=timeout)  # nosec B310

    def _codex_headers(self, payload: dict, lite: bool) -> dict:
        model = payload.get("model") if isinstance(payload.get("model"), str) else ""
        return codex_headers(self.server.upstream_token, model, version=self.server.codex_version,
                             session_id=self.server.session_id, lite=lite)

    def _upstream_models(self) -> list:
        """The upstream catalogue, or the default model when it cannot answer.

        The ChatGPT Codex route has no useful /models list. Advertise the
        catalog slugs (and the launched model) without a network call.
        """
        if self.server.upstream_kind == "responses":
            names = []
            for item in self.server.catalog:
                slug = item.get("slug") if isinstance(item, dict) else ""
                if isinstance(slug, str) and slug and slug not in names:
                    names.append(slug)
            default = self.server.default_model
            if default and default not in names:
                names.insert(0, default)
            return names or [default or "gpt-6.1-sol"]
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
            extra = None
            if self.server.upstream_kind == "openai":
                payload, path = build_openai_chat(request, model, stream), "/chat/completions"
            elif self.server.upstream_kind == "responses":
                payload, lite = build_responses(request, model, stream, codex=self.server.codex,
                                                catalog=self.server.catalog)
                path = "/responses"
                if self.server.codex:
                    extra = self._codex_headers(payload, lite)
            else:
                payload, path = build_chat(request, model, stream), "/api/chat"
        except RequestError as exc:
            self._send_error(exc.code, exc.message)
            return

        try:
            resp = self._upstream(path, payload, extra_headers=extra)
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
            if self.server.upstream_kind == "responses":
                if stream:
                    self._stream(resp, model, parsed, self._relay_responses)
                else:
                    self._complete_responses(resp, model)
            elif stream:
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

    def _consume_responses(self, events) -> ResponsesAccum:
        acc = ResponsesAccum()
        for event in events:
            acc.feed(event)
            if acc.error or acc.done:
                break
        return acc

    def _complete_responses(self, resp, model: str) -> None:
        """Fold a Responses reply into one Gemini object.

        Codex rejects stream=false, so a generateContent client still receives
        SSE from the upstream. A plain Responses server may answer with one
        JSON object instead; both shapes land here.
        """
        try:
            raw = resp.read()
        except Exception as e:
            self._send_error(502, f"Failed reading upstream response: {e}")
            return
        ctype = (resp.headers.get("Content-Type") or "").lower()
        if "text/event-stream" in ctype or raw.lstrip().startswith(b"data:"):
            acc = self._consume_responses(iter_sse_events(raw.splitlines()))
            if acc.error:
                self._send_error(502, acc.error)
                return
            if not acc.done:
                self._send_error(502, "Upstream stream ended before completion.")
                return
            self._send_json_response(200, acc.folded(model))
            return
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as e:
            self._send_error(502, f"Failed reading upstream response: {e}")
            return
        if not isinstance(parsed, dict):
            self._send_error(502, "Upstream JSON was not an object.")
            return
        if parsed.get("error"):
            detail = parsed["error"]
            message = detail.get("message") if isinstance(detail, dict) else detail
            self._send_error(502, f"Upstream error: {message}")
            return
        acc = ResponsesAccum()
        acc.usage = usage_responses(parsed)
        acc.finish = "MAX_TOKENS" if parsed.get("status") == "incomplete" else "STOP"
        acc.done = True
        acc._absorb_output(parsed.get("output"))
        self._send_json_response(200, acc.folded(model))

    def _relay_responses(self, resp, model: str, emit) -> None:
        """Read a Responses SSE stream and emit Gemini objects."""
        acc = ResponsesAccum()
        for event in iter_sse_events(resp):
            parts = acc.feed(event)
            if acc.error:
                emit(error_body(502, acc.error))
                return
            if parts:
                emit({"candidates": [candidate(parts, None)], "modelVersion": model})
            if acc.done:
                break
        if not acc.done:
            emit(error_body(502, "Upstream stream ended before completion."))
            return
        emit(acc.terminal(model))

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
                 upstream_kind: str = "ollama", codex: bool = False):
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
        # environment, never argv, and goes only to the upstream. The raw
        # token is kept so a Codex JWT can yield Chatgpt-Account-Id.
        self.upstream_token = upstream_token
        self.upstream_auth = f"Bearer {upstream_token}" if upstream_token else ""
        # Key clients must present (see GeminiShimHandler._authorized); also
        # from the environment only. Empty leaves the shim open, as before.
        self.client_key = client_key
        # ChatGPT Codex headers and body, only when the launcher says this
        # upstream is that route. A generic Responses server does not get them.
        self.codex = bool(codex)
        self.catalog: list = []
        self.codex_version = CODEX_VERSION_DEFAULT
        self.session_id = uuid.uuid4().hex
        if self.codex:
            self.catalog, self.codex_version = load_codex_meta()


def main() -> None:
    parser = argparse.ArgumentParser(description="Gemini wire-format translation shim")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host address")
    parser.add_argument("--port", type=int, default=0, help="Bind port (0 for dynamic)")
    parser.add_argument("--upstream", default="http://127.0.0.1:11434", help="Upstream base URL")
    parser.add_argument("--upstream-kind", default="ollama", choices=UPSTREAM_KINDS,
                        help="Wire the upstream speaks: ollama (/api/chat), openai (/chat/completions), or responses (/responses)")
    parser.add_argument("--default-model", default="kalidroid-27b:latest", help="Default target model")
    parser.add_argument("--print-port", action="store_true", help="Print bound port to stdout")
    args = parser.parse_args()

    try:
        server = GeminiShimServer((args.host, args.port), args.upstream, args.default_model,
                                  os.environ.get("KIMO_SHIM_UPSTREAM_TOKEN", ""),
                                  client_key=os.environ.get("KIMO_SHIM_CLIENT_KEY", ""),
                                  upstream_kind=args.upstream_kind,
                                  codex=os.environ.get("KIMO_SHIM_CODEX") == "1")
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
