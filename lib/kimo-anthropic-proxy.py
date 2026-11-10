#!/usr/bin/env python3
"""Local Anthropic Messages proxy for `kimo launch claude --provider`.

Claude Code posts `/v1/messages`. OpenAI, the ChatGPT Codex backend, xAI,
QwenCloud, Gemini's OpenAI surface, vLLM and Alibaba's free-tier
compatible-mode endpoint do not speak that wire. This process binds
127.0.0.1, checks a per-launch client token, and translates one request
into either Chat Completions or the Responses API.

`--wire messages` does not translate. Ollama Cloud already speaks Messages.
Claude Code 2.1.321 still renames the model on resume: a session whose
stored model is a first-party id (Fable, claude-fable-5-2, or the current
default "beam") makes the next launch send `beam` or `beam[1m]`. A host that
does not serve that id reports the model missing, and the client then stays
on beam. This wire strips the suffix, rewrites a resumed first-party id to
the launched model, and echoes the id Claude asked for so its existence
check still passes.

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
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import uuid
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable
from urllib.parse import unquote, urlsplit

MAX_BODY = 32 * 1024 * 1024
SUFFIX = re.compile(r"\[[^\[\]]+\]$")
MESSAGE_PATHS = {"/v1/messages", "/messages"}
COUNT_PATHS = {"/v1/messages/count_tokens", "/messages/count_tokens"}
MODELS_PATHS = {"/v1/models", "/models"}
# Rows we previously wrote into Claude settings. A later launch removes an
# allowlist made only of these plus the live catalog; availableModels replaces
# the built-in lineup, which is how a resumed session lost every Codex model.
KIMO_PICKER_MARK = "kimo:codex"

FALLBACK_CODEX_MODELS: list[tuple[str, str, int, str]] = [
    ("gpt-6.1-sol", "GPT-6.1-Sol", 272000, "Latest workhorse model for coding and everyday work."),
    ("gpt-6-astra", "GPT-6 Astra", 272000, "Deep reasoning frontier model."),
    ("gpt-6.1-terra", "GPT-6.1 Terra", 272000, "Fast, lightweight reasoning model."),
    ("gpt-6-sol", "GPT-6 Sol", 272000, "High-performance coding model."),
    ("gpt-5.1-codex", "GPT-5.1 Codex", 272000, "Fast, lightweight coding model."),
    ("gpt-5.1", "GPT-5.1", 128000, "Broad capabilities across text and code."),
    ("gpt-4o", "GPT-4o", 128000, "Versatile flagship model."),
    ("gpt-4o-mini", "GPT-4o mini", 128000, "Fast and affordable model for everyday tasks."),
    ("o1", "o1", 200000, "Reasoning model designed for complex problems."),
    ("o3-mini", "o3-mini", 200000, "Efficient reasoning model for code and math."),
]

PROVIDER_MODELS: dict[str, list[tuple[str, str, int, str]]] = {
    "xai": [
        ("grok-4.7", "Grok 4.7", 500000, "Latest Grok reasoning model"),
        ("grok-4.6", "Grok 4.6", 500000, "Grok 4.6 reasoning model"),
        ("grok-4", "Grok 4", 500000, "Grok 4 model"),
        ("grok-beta", "Grok Beta", 131072, "Grok beta release"),
        ("grok-2", "Grok 2", 131072, "Grok 2 model"),
    ],
    "grok": [
        ("grok-4.7", "Grok 4.7", 500000, "Latest Grok reasoning model"),
        ("grok-4.6", "Grok 4.6", 500000, "Grok 4.6 reasoning model"),
        ("grok-4", "Grok 4", 500000, "Grok 4 model"),
        ("grok-beta", "Grok Beta", 131072, "Grok beta release"),
        ("grok-2", "Grok 2", 131072, "Grok 2 model"),
    ],
    "gemini": [
        ("gemini-2.5-flash", "Gemini 2.5 Flash", 1000000, "Next-gen multimodal flash model"),
        ("gemini-2.5-pro", "Gemini 2.5 Pro", 1000000, "Next-gen multimodal pro model"),
        ("gemini-2.0-flash", "Gemini 2.0 Flash", 1000000, "Fast multimodal model"),
        ("gemini-1.5-pro", "Gemini 1.5 Pro", 2000000, "Long-context reasoning model"),
        ("gemini-1.5-flash", "Gemini 1.5 Flash", 1000000, "Fast lightweight model"),
    ],
    "kalidroid": [
        ("qwen3.8-27b", "Qwen 3.8 27B", 131072, "Kalidroid house model"),
        ("qwen3.8-27b-uncensored", "Qwen 3.8 27B Uncensored", 131072, "Uncensored Qwen 3.8 27B via Kalidroid"),
        ("kimi-k2.6", "Kimi K2.6", 131072, "Kimi K2.6 via Kalidroid"),
        ("kimi-k2.7-code", "Kimi K2.7 Code", 131072, "Kimi K2.7 coding model via Kalidroid"),
        ("kimi-k2.7-code-highspeed", "Kimi K2.7 Code Highspeed", 131072, "Faster Kimi K2.7 code model via Kalidroid"),
        ("kimi-k3", "Kimi K3", 131072, "Kimi K3 via Kalidroid"),
        ("kimi-k3.1-pro", "Kimi K3.1 Pro", 131072, "Kimi K3.1 Pro via Kalidroid"),
    ],
    "dashscope": [
        ("qwen3.8-max", "Qwen 3.8 Max", 1000000, "Frontier Qwen model"),
        ("qwen3.8-flash", "Qwen 3.8 Flash", 1000000, "Ultra-fast Qwen model"),
        ("qwen3.6-flash", "Qwen 3.6 Flash", 1000000, "Lightweight Qwen model"),
        ("qwen3-coder-plus", "Qwen 3 Coder Plus", 1000000, "Specialized coding model"),
        ("qwen3-coder-turbo", "Qwen 3 Coder Turbo", 1000000, "Fast coding model"),
    ],
    "qwencloud": [
        ("qwen3.8-max", "Qwen 3.8 Max", 1000000, "Frontier Qwen model"),
        ("qwen3.8-flash", "Qwen 3.8 Flash", 1000000, "Ultra-fast Qwen model"),
        ("qwen3.6-flash", "Qwen 3.6 Flash", 1000000, "Lightweight Qwen model"),
        ("qwen3-coder-plus", "Qwen 3 Coder Plus", 1000000, "Specialized coding model"),
        ("qwen3-coder-turbo", "Qwen 3 Coder Turbo", 1000000, "Fast coding model"),
    ],
    "abliteration": [
        ("abliterated-model-large-v2", "Abliterated Model Large v2", 1000000, "Uncensored frontier model"),
        ("abliterated-model-large", "Abliterated Model Large", 1000000, "Large uncensored model"),
        ("abliterated-model", "Abliterated Model", 1000000, "Base uncensored model"),
    ],
}


def build_catalog(provider: str, active_model: str | None = None) -> list[dict]:
    catalog: list[dict] = []
    seen: set[str] = set()

    def add_item(slug: str, name: str, ctx: int, desc: str, **extra: object) -> None:
        if not slug or slug in seen:
            return
        seen.add(slug)
        row = {
            "slug": slug,
            "display_name": name or slug,
            "context_window": ctx,
            "description": desc or f"{name or slug} via {provider or 'codex'}",
        }
        for key, value in extra.items():
            if value not in (None, "", False):
                row[key] = value
        catalog.append(row)

    loaded = False
    if provider in ("codex", "openai"):
        # Cache first. A stub for the launched slug must not hide the cache
        # row: that row carries the display name, the real context window,
        # and whether the ChatGPT route expects the responses-lite shape.
        codex_home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
        cache_path = codex_home / "models_cache.json"
        if cache_path.is_file():
            try:
                data = json.loads(cache_path.read_text(encoding="utf-8"))
                if isinstance(data, dict) and isinstance(data.get("models"), list):
                    for m in data["models"]:
                        if not isinstance(m, dict):
                            continue
                        if m.get("visibility", "list") != "list":
                            continue
                        slug = m.get("slug")
                        if isinstance(slug, str) and slug:
                            name = m.get("display_name") or slug
                            desc = m.get("description") or ""
                            ctx = m.get("context_window") or m.get("max_context_window") or 272000
                            try:
                                ctx_i = int(ctx)
                            except (TypeError, ValueError):
                                ctx_i = 272000
                            level = m.get("default_reasoning_level")
                            add_item(
                                slug,
                                name if isinstance(name, str) else slug,
                                ctx_i if ctx_i > 0 else 272000,
                                desc if isinstance(desc, str) else "",
                                default_reasoning_level=level if isinstance(level, str) else "",
                                use_responses_lite=m.get("use_responses_lite") is True,
                            )
                            loaded = True
            except Exception:
                pass
        if not loaded:
            for slug, name, ctx, desc in FALLBACK_CODEX_MODELS:
                add_item(slug, name, ctx, desc)
    elif provider in PROVIDER_MODELS:
        for slug, name, ctx, desc in PROVIDER_MODELS[provider]:
            add_item(slug, name, ctx, desc)

    clean_active = bare_model(active_model) if active_model else ""
    # Launch sets this to the window it told Claude. An id that is not already
    # in the static catalog (an explicit --model) has to report that window,
    # or /model assumes 200K and a resumed session compacts early.
    stub_ctx = _positive_int(os.environ.get("KIMO_CLAUDE_CATALOG_CTX", ""), 272000)
    if provider == "alibaba":
        clean_active = _alibaba_wire_id(clean_active)
    if clean_active and clean_active != "claude" and clean_active not in seen:
        add_item(clean_active, clean_active, stub_ctx, f"{clean_active} active model")

    return catalog


COMPAT_ALIASES: list[str] = [
    "claude-opus-5-5",
    "opus-5.5",
    "opus",
    "claude-opus-4-8",
    "claude-opus-5",
    "claude-sonnet-5-5",
    "claude-sonnet-4-5",
    "claude-sonnet-5",
    "sonnet",
    "claude-3-5-haiku",
    "claude-3-5-haiku-20241022",
    "haiku",
    "default",
    "claude",
]


def request_path(raw: str) -> str:
    """Path Claude Code requested, with a doubled /v1 collapsed.

    ANTHROPIC_BASE_URL is the origin and ANTHROPIC_API_BASE already ends in
    /v1. A client that appends /v1/messages to the latter asks for
    /v1/v1/messages. Claude Code shows every 404 as "the selected model may
    not exist", so both spellings have to hit the Messages handler.
    """
    path = unquote(urlsplit(raw).path or "/")
    while "//" in path:
        path = path.replace("//", "/")
    while "/v1/v1" in path:
        path = path.replace("/v1/v1", "/v1")
    return path.rstrip("/") or "/"


def _norm_model(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", text.lower())


def is_anthropic_model(model: str) -> bool:
    """True for an id Claude Code sends when it still means Opus, Sonnet, or Haiku.

    A resumed session stores the built-in alias (opus, opus-5.5,
    claude-opus-5-5). Those are not Codex slugs. gpt-6.1-sol is not one of
    them, and neither is a claude-codex-<slug> discovery alias: the caller
    strips that prefix before asking.
    """
    lower = model.lower()
    # "beam" is the first-party id Claude Code 2.1.321 stores and sends on
    # resume (the successor of Fable). It is not a Kalidroid or Codex slug.
    if lower in COMPAT_ALIASES or lower in {"fable", "beam", "best", "opusplan", "inherit"}:
        return True
    if lower.startswith("claude-") or lower.startswith("anthropic/"):
        return True
    if re.fullmatch(r"(opus|sonnet|haiku|fable|beam)([-.][0-9]+)*", lower):
        return True
    # "Fable 5.2" is the picker label. The wire id is usually claude-fable-5-2,
    # but a resume can hand the label across with a space in it.
    folded = _norm_model(lower)
    return re.fullmatch(r"(opus|sonnet|haiku|fable|beam)[0-9]*", folded) is not None


def _behaves_as(ctx: object) -> str:
    """Native id Claude Code will accept for a model it does not know.

    A modelPicker row without behavesAs is not offered. 1M uses the native
    1M opus; anything smaller uses haiku (200K). The id sent to the proxy
    stays the catalog slug. Resume may still ask for beam; the proxy rewrites
    that, and the launch pins keep the selected model on the catalog slug.
    """
    try:
        window = int(ctx)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        window = 0
    if window >= 1_000_000:
        return "claude-opus-4-8"
    return "claude-haiku-4-5"


def _populate_claude_settings(catalog: list[dict], provider: str, chosen_model: str = "") -> None:
    """Add provider slugs to the user-level /model picker.

    modelPicker is read from user settings only; project and local settings
    are ignored, and writing them would also dirty a repo's .claude directory.
    availableModels is an allowlist that replaces the built-in lineup, so a
    previous launch's list is removed when every entry is one we would have
    written. The session model itself stays on --model / ANTHROPIC_MODEL:
    persisting it here would stick a hosted slug on later plain `claude` runs,
    and a settings env block would outrank the launch environment.

    Claude Code 2.1.321 does not offer a row for an id it does not know unless
    behavesAs names a native model, and /model then probes the API. That probe
    has no Anthropic credential on a kimo launch (the key stays in the proxy),
    so it fails with "Could not resolve authentication method" and the client
    keeps beam. behavesAs makes the row selectable without that probe.
    Codex and OpenAI slugs are discovered through the gateway and stay without
    behavesAs: adding it makes a resume send beam.
    """
    if not catalog:
        return
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    settings_file = claude_home / "settings.json"
    owned = {item["slug"] for item in catalog} | set(COMPAT_ALIASES)
    try:
        claude_home.mkdir(parents=True, exist_ok=True)
        doc: dict = {}
        if settings_file.is_file():
            try:
                parsed = json.loads(settings_file.read_text(encoding="utf-8"))
                if isinstance(parsed, dict):
                    doc = parsed
            except (OSError, json.JSONDecodeError):
                doc = {}

        picker = doc.get("modelPicker")
        if not isinstance(picker, dict):
            picker = {}
        kept: list[dict] = []
        seen: set[str] = set()
        raw_options = picker.get("options")
        if isinstance(raw_options, list):
            for opt in raw_options:
                if not isinstance(opt, dict) or not isinstance(opt.get("model"), str):
                    continue
                if opt.get("kimo") == KIMO_PICKER_MARK or opt["model"] in owned:
                    continue
                kept.append(opt)
                seen.add(opt["model"])
        ordered = list(catalog)
        chosen_slug = bare_model(chosen_model) if chosen_model else ""
        if chosen_slug.startswith("claude-codex-"):
            chosen_slug = chosen_slug[len("claude-codex-"):]
        if chosen_slug:
            ordered.sort(key=lambda item: 0 if item["slug"] == chosen_slug else 1)
        for item in ordered:
            slug = item["slug"]
            if slug in seen:
                continue
            row = {
                "model": slug,
                "label": item.get("display_name") or slug,
                "description": item.get("description") or f"{slug} via {provider or 'codex'}",
                "kimo": KIMO_PICKER_MARK,
            }
            if provider not in ("codex", "openai", ""):
                row["behavesAs"] = _behaves_as(item.get("context_window"))
            kept.append(row)
            seen.add(slug)
        picker["options"] = kept
        picker.setdefault("replaceBuiltInOptions", False)
        doc["modelPicker"] = picker

        existing_available = doc.get("availableModels")
        if (
            isinstance(existing_available, list)
            and existing_available
            and all(isinstance(entry, str) and entry in owned for entry in existing_available)
            and any(entry not in COMPAT_ALIASES for entry in existing_available)
        ):
            doc.pop("availableModels", None)

        fd, temp = tempfile.mkstemp(prefix=f"{settings_file.name}.", dir=str(claude_home))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(doc, handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp, 0o600)
            os.replace(temp, settings_file)
        finally:
            if os.path.exists(temp):
                try:
                    os.unlink(temp)
                except OSError:
                    pass
    except OSError:
        return


class ProxyError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def rewrite_asked_model(value: object, upstream_model: str, asked: str) -> object:
    """Put Claude's id back on a Messages body the upstream answered as `upstream_model`.

    The existence check compares the response model with the id Claude sent.
    Returning `beam` for a `beam[1m]` probe is reported as "may not exist".
    """
    if not asked or asked == upstream_model:
        return value
    if isinstance(value, dict):
        rewritten: dict = {}
        for key, item in value.items():
            if key == "model" and item == upstream_model:
                rewritten[key] = asked
            else:
                rewritten[key] = rewrite_asked_model(item, upstream_model, asked)
        return rewritten
    if isinstance(value, list):
        return [rewrite_asked_model(item, upstream_model, asked) for item in value]
    return value


def rewrite_sse_line(line: bytes, upstream_model: str, asked: str) -> bytes:
    """Rewrite one SSE line. Non-data lines and non-JSON data stay as they were."""
    if not asked or asked == upstream_model:
        return line
    marker = b"data:"
    index = line.find(marker)
    if index < 0:
        return line
    raw = line[index + len(marker):].strip()
    if not raw or raw == b"[DONE]":
        return line
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return line
    parsed = rewrite_asked_model(parsed, upstream_model, asked)
    return line[:index] + b"data: " + json.dumps(parsed, separators=(",", ":")).encode("utf-8")


def bare_model(model: object) -> str:
    text = model if isinstance(model, str) else ""
    text = SUFFIX.sub("", text).strip()
    return text or "claude"


def _alibaba_wire_id(model: str) -> str:
    """Bare id Model Studio's compatible-mode endpoint expects.

    Kimi stores free-tier rows as alibaba/<slug> (or modelscope/<slug>). The
    chat body has to carry the slug alone. The Messages response still echoes
    whatever id the client asked for.
    """
    for prefix in ("alibaba/", "modelscope/"):
        if model.startswith(prefix):
            return model[len(prefix):]
    return model


def _positive_int(raw: str, default: int) -> int:
    try:
        ctx = int(raw)
    except (TypeError, ValueError):
        return default
    return ctx if ctx > 0 else default


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


def resolve_upstream_model(
    model: object,
    provider: str = "",
    active_model: str = "",
    catalog: list[dict] | None = None,
) -> str:
    """Codex slug for a Messages `model` field.

    Claude Code verifies any id it does not already know by calling the
    gateway, and it reports a 404 as "the selected model may not exist".
    Catalog slugs (gpt-6.1-sol) and their display names pass through unchanged.
    A resumed session's opus / opus-5.5 / claude-opus-5-5 alias is rewritten
    to the launched slug so that request reaches the Codex backend too.
    """
    clean = bare_model(model)
    if provider == "alibaba":
        clean = _alibaba_wire_id(clean)
    if clean.startswith("claude-codex-"):
        clean = clean[len("claude-codex-"):]
    lower = clean.lower()
    folded = _norm_model(clean)
    cat = catalog or []

    for item in cat:
        slug = item["slug"]
        if slug.lower() == lower or _norm_model(slug) == folded:
            return slug
        display = item.get("display_name") if isinstance(item.get("display_name"), str) else ""
        if display and _norm_model(display) == folded:
            return slug

    def launched() -> str:
        active = bare_model(active_model) if active_model else ""
        if provider == "alibaba":
            active = _alibaba_wire_id(active)
        if active.startswith("claude-codex-"):
            active = active[len("claude-codex-"):]
        if active and not is_anthropic_model(active):
            for item in cat:
                if item["slug"].lower() == active.lower():
                    return item["slug"]
            return active
        if cat:
            return cat[0]["slug"]
        return "gpt-6.1-sol"

    if is_anthropic_model(clean):
        if "haiku" in lower or lower.endswith("fast"):
            for item in cat:
                slug_l = item["slug"].lower()
                if any(k in slug_l for k in ("terra", "mini", "flash", "haiku")):
                    return item["slug"]
        return launched()

    # Alibaba's free-tier key cannot serve a Codex slug. A previous
    # `launch claude --provider codex` leaves CLAUDE_CODE_SUBAGENT_MODEL
    # and the family pins set to gpt-6.1-sol in user settings, and that
    # file outranks the launch environment. Subagents then send gpt-6.1-sol
    # and DashScope answers 404, which Claude Code reports as "may not exist".
    # Anything that is not the launched free-tier id is rewritten to it.
    if provider == "alibaba":
        return launched()

    if clean and clean != "claude":
        return clean
    return launched()


def to_chat(
    payload: dict,
    provider: str = "",
    active_model: str = "",
    catalog: list[dict] | None = None,
) -> dict:
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
    target_model = resolve_upstream_model(
        payload.get("model"), provider, active_model, catalog
    )
    out = {
        "model": target_model,
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


def to_responses(
    payload: dict,
    provider: str = "",
    active_model: str = "",
    catalog: list[dict] | None = None,
) -> dict:
    items = []
    known_tool_calls: set[str] = set()

    for message in payload.get("messages") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if role == "user":
            for tool_id, text in _tool_results(content):
                if tool_id in known_tool_calls:
                    items.append({"type": "function_call_output", "call_id": tool_id, "output": text})
                else:
                    items.append({
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": f"Tool output ({tool_id}):\n{text}"}],
                    })
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
                call_id = call["id"]
                known_tool_calls.add(call_id)
                items.append({
                    "type": "function_call",
                    "call_id": call_id,
                    "name": call["name"],
                    "arguments": call["arguments"],
                })

    if not items:
        items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Hello"}]}]

    target_model = resolve_upstream_model(
        payload.get("model"), provider, active_model, catalog
    )
    out = {
        "model": target_model,
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
    if provider == "codex":
        _apply_codex_request(out, catalog or [])
    return out


def _apply_codex_request(out: dict, catalog: list[dict]) -> None:
    """Fill the fields the ChatGPT Codex route rejects when they are absent.

    stream and store are set by the caller. A request that reaches
    chatgpt.com/backend-api/codex/responses without instructions, or without
    the responses-lite contract on a model the catalog marks that way, comes
    back 404. Claude Code reports that 404 as "the selected model may not
    exist".
    """
    item = None
    slug = out.get("model") if isinstance(out.get("model"), str) else ""
    for candidate in catalog:
        if candidate.get("slug") == slug:
            item = candidate
            break
    instructions = out.get("instructions")
    if not isinstance(instructions, str) or not instructions.strip():
        out["instructions"] = "You are a coding assistant."
    include = out.get("include")
    if not isinstance(include, list):
        include = []
    if "reasoning.encrypted_content" not in include:
        include.append("reasoning.encrypted_content")
    out["include"] = include
    effort = ""
    lite = False
    if item:
        level = item.get("default_reasoning_level")
        if isinstance(level, str):
            effort = level
        lite = item.get("use_responses_lite") is True
    if effort and not isinstance(out.get("reasoning"), dict):
        out["reasoning"] = {"effort": effort, "summary": "auto"}
    if lite:
        reasoning = out.get("reasoning")
        if not isinstance(reasoning, dict):
            reasoning = {}
            out["reasoning"] = reasoning
        reasoning.setdefault("context", "all_turns")
        out["parallel_tool_calls"] = False


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
        self.thinking_carry = ""

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
        if self.blocks[self.open_index]["type"] == "thinking":
            self._flush_thinking()
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

    def _write_thinking(self, piece: str) -> None:
        if not piece:
            return
        block = self._open_text("thinking")
        block["thinking"] += piece
        self._send("content_block_delta", {
            "type": "content_block_delta",
            "index": self.open_index,
            "delta": {"type": "thinking_delta", "thinking": piece},
        })

    def _flush_thinking(self) -> None:
        pending = self.thinking_carry
        self.thinking_carry = ""
        self._write_thinking(pending)

    def thinking(self, piece: object) -> None:
        if not isinstance(piece, str) or not piece:
            return
        clean = re.sub(r"</?think>", "", self.thinking_carry + piece, flags=re.IGNORECASE)
        self.thinking_carry = ""
        for length in range(min(len(clean), 6), 0, -1):
            suffix = clean[-length:].lower()
            if "<think>".startswith(suffix) or "</think>".startswith(suffix):
                self.thinking_carry = clean[-length:]
                clean = clean[:-length]
                break
        self._write_thinking(clean)

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
        self._flush_thinking()
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
    active_model = ""
    client_token = ""
    timeout = 600
    catalog: list[dict] = []
    session_id = ""
    codex_version = "0.167.0"

    def do_POST(self) -> None:
        try:
            self._handle()
        except ProxyError as exc:
            self._json(exc.status, error_body(exc.status, redact(exc.message, self._secret())))
        except Exception as exc:  # noqa: BLE001 - last-resort client error, never a traceback
            self._json(500, error_body(500, redact(str(exc), self._secret())))

    def do_GET(self) -> None:
        try:
            if not self._authorized():
                raise ProxyError(401, "invalid proxy token")
            path = request_path(self.path)
            if path in MODELS_PATHS:
                self._serve_models_list()
                return
            if path.startswith("/v1/models/") or path.startswith("/models/"):
                self._serve_single_model(unquote(path.split("/")[-1]))
                return
            self._json(404, error_body(404, "not found"))
        except ProxyError as exc:
            self._json(exc.status, error_body(exc.status, redact(exc.message, self._secret())))
        except Exception as exc:  # noqa: BLE001
            self._json(500, error_body(500, redact(str(exc), self._secret())))

    def _serve_models_list(self) -> None:
        data = []
        seen = set()
        for item in self.catalog:
            slug = item["slug"]
            seen.add(slug)
            ctx = item.get("context_window") or 272000
            data.append({
                "type": "model",
                "object": "model",
                "id": slug,
                "display_name": item.get("display_name") or slug,
                "created_at": "2025-01-01T00:00:00Z",
                "created": 1735689600,
                "owned_by": self.provider or "system",
                "max_input_tokens": ctx,
                "max_tokens": 128000,
                "context_window": ctx,
            })
            # Gateway discovery keeps an id only when it contains "claude" or
            # "anthropic". The picker row still sends this alias; resolve maps
            # it back to the slug. The raw slug is what /model saves.
            alias = f"claude-codex-{slug}"
            if alias not in seen:
                seen.add(alias)
                data.append({
                    "type": "model",
                    "object": "model",
                    "id": alias,
                    "display_name": item.get("display_name") or slug,
                    "description": item.get("description") or "",
                    "created_at": "2025-01-01T00:00:00Z",
                    "created": 1735689600,
                    "owned_by": self.provider or "system",
                    "max_input_tokens": ctx,
                    "max_tokens": 128000,
                    "context_window": ctx,
                })
        body = json.dumps({"object": "list", "data": data, "has_more": False}).encode("utf-8")
        self._json(200, body)

    def _serve_single_model(self, model_id: str) -> None:
        # Echo the requested id. Substituting a different id makes the client's
        # existence check fail, which Claude Code surfaces as "may not exist".
        asked = model_id or "claude"
        bare = bare_model(asked)
        if self.provider == "alibaba":
            bare = _alibaba_wire_id(bare)
        lookup = bare[len("claude-codex-"):] if bare.startswith("claude-codex-") else bare
        folded = _norm_model(lookup)
        ctx = 272000
        name = asked
        for item in self.catalog:
            slug = item["slug"]
            display = item.get("display_name") if isinstance(item.get("display_name"), str) else ""
            if slug == lookup or slug.lower() == lookup.lower() or _norm_model(slug) == folded or (display and _norm_model(display) == folded):
                ctx = int(item.get("context_window") or ctx)
                name = display or slug
                break
        body = json.dumps({
            "type": "model",
            "object": "model",
            "id": asked,
            "display_name": name,
            "created_at": "2025-01-01T00:00:00Z",
            "created": 1735689600,
            "owned_by": self.provider or "system",
            "max_input_tokens": ctx,
            "max_tokens": 128000,
            "context_window": ctx,
        }).encode("utf-8")
        self._json(200, body)

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
        path = request_path(self.path)
        payload = self._read_json()
        if path in COUNT_PATHS:
            self._json(200, json.dumps({"input_tokens": estimate_tokens(payload)}).encode())
            return
        if self.wire == "messages":
            if path not in MESSAGE_PATHS:
                raise ProxyError(404, "not found")
            self._forward_messages(payload, path)
            return
        if path not in MESSAGE_PATHS:
            raise ProxyError(404, "not found")
        # A grok-login JWT is aimed at cli-chat-proxy.grok.com. That host speaks
        # Chat Completions, routes on x-grok-model-override, and requires
        # X-XAI-Token-Auth. Responses on that host 401s with x_xai_token_auth=none.
        wire = "chat" if grok_cli_host(self.upstream) else self.wire
        translated = (
            to_chat(payload, self.provider, self.active_model, self.catalog)
            if wire == "chat"
            else to_responses(payload, self.provider, self.active_model, self.catalog)
        )
        model = translated["model"]
        # Claude's existence check compares the Messages `model` field with the
        # id it sent. The upstream call still uses the catalog slug.
        asked = payload.get("model")
        shown = asked.strip() if isinstance(asked, str) and asked.strip() else model
        client_stream = bool(payload.get("stream"))
        if wire == "chat" and grok_cli_host(self.upstream):
            translated["stream"] = True
        # The ChatGPT Codex route only answers a streaming Responses call.
        # A non-stream verify (the request Claude Code sends for an id it does
        # not know) is a 404, which the client reports as a missing model.
        if self.provider == "codex" and wire == "responses":
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
            builder = Builder(shown, self._sse_emit if client_stream else None)
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

    def _forward_messages(self, payload: dict, path: str) -> None:
        """Forward one Messages call. The upstream sees the hosted id.

        A resumed Fable session and a beam[1m] probe both become the launched
        model. The response still carries the id Claude sent.
        """
        asked_raw = payload.get("model")
        asked = asked_raw.strip() if isinstance(asked_raw, str) and asked_raw.strip() else (self.active_model or "claude")
        upstream_model = resolve_upstream_model(asked, self.provider, self.active_model, self.catalog)
        outgoing = dict(payload)
        outgoing["model"] = upstream_model
        secret = self._secret()
        if self.env_key and not secret:
            raise ProxyError(502, f"{self.env_key} is empty; the upstream credential is missing")
        conn, upstream = self._open_messages(outgoing, secret, path)
        try:
            status = upstream.status
            content_type = upstream.headers.get("Content-Type") or ""
            client_stream = bool(payload.get("stream")) or "text/event-stream" in content_type
            if client_stream and status < 400:
                self.send_response(status)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
                pending = b""
                while True:
                    chunk = upstream.read(8192)
                    if not chunk:
                        break
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        self.wfile.write(rewrite_sse_line(line, upstream_model, asked) + b"\n")
                if pending:
                    self.wfile.write(rewrite_sse_line(pending, upstream_model, asked))
                try:
                    self.wfile.flush()
                except BrokenPipeError:
                    return
                return
            raw = upstream.read(MAX_BODY)
            text = redact(raw.decode("utf-8", "replace"), secret)
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, (dict, list)):
                parsed = rewrite_asked_model(parsed, upstream_model, asked)
                self._json(status, json.dumps(parsed).encode("utf-8"))
                return
            body = text.encode("utf-8")
            try:
                self.send_response(status)
                self.send_header("Content-Type", content_type.split(";", 1)[0] or "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except BrokenPipeError:
                return
        finally:
            conn.close()

    def _open_messages(self, payload: dict, secret: str, path: str):
        parts = urlsplit(self.upstream.rstrip("/"))
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ProxyError(502, "upstream URL is not http(s)")
        upstream_path = path if path.startswith("/") else "/" + path
        if parts.path and parts.path != "/":
            upstream_path = parts.path.rstrip("/") + upstream_path
        data = json.dumps(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Accept": self.headers.get("Accept") or "application/json, text/event-stream",
            "Content-Length": str(len(data)),
            "Host": parts.netloc,
        }
        if secret and secret != "EMPTY":
            headers["Authorization"] = f"Bearer {secret}"
        for name in ("anthropic-version", "anthropic-beta"):
            value = self.headers.get(name)
            if value:
                headers[name] = value
        connection_cls = HTTPSConnection if parts.scheme == "https" else HTTPConnection
        port = parts.port or (443 if parts.scheme == "https" else 80)
        try:
            conn = connection_cls(parts.hostname, port, timeout=self.timeout)
            conn.request("POST", upstream_path, body=data, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            raise ProxyError(502, f"upstream unreachable: {exc}") from exc
        return conn, upstream

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
            # responses=v1 is the old beta flag. The ChatGPT route answers it
            # with an HTML 404, and Claude Code turns every 404 into
            # "There's an issue with the selected model (<slug>)".
            # responses=experimental is what the current HTTP client sends.
            headers["Accept"] = "text/event-stream"
            headers["OpenAI-Beta"] = os.environ.get("KIMO_CODEX_OPENAI_BETA", "responses=experimental")
            headers["originator"] = os.environ.get("KIMO_CODEX_ORIGINATOR", "codex_cli_rs")
            headers["version"] = self.codex_version or "0.167.0"
            headers["session_id"] = self.session_id or "kimo"
            headers["session-id"] = headers["session_id"]
            headers["User-Agent"] = f"codex_cli_rs/{headers['version']}"
            wire_model = payload.get("model")
            if isinstance(wire_model, str) and wire_model:
                headers["x-codex-routing-hint"] = f"model={wire_model}"
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
    parser.add_argument("--wire", choices=("chat", "responses", "messages"), required=True)
    parser.add_argument("--env-key", default="")
    parser.add_argument("--provider", default="")
    parser.add_argument("--model", default="")
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
    Proxy.active_model = args.model
    Proxy.client_token = token
    catalog = build_catalog(args.provider, args.model)
    Proxy.catalog = catalog
    Proxy.session_id = uuid.uuid4().hex
    if args.provider == "codex":
        cache_path = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "models_cache.json"
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            version = cached.get("client_version") if isinstance(cached, dict) else ""
            if isinstance(version, str) and version:
                Proxy.codex_version = version
        except (OSError, json.JSONDecodeError):
            pass
    # ollama-cloud has its own catalog writer, and Alibaba free-tier launches
    # must not install one. Hosted provider slugs otherwise have to be in the
    # user picker before Claude starts, or /model probes the API and resume
    # drops back to the first-party model.
    if args.provider not in ("", "ollama-cloud", "alibaba") and catalog:
        _populate_claude_settings(catalog, args.provider, args.model)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    port = server.server_address[1]
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    threading.Thread(target=_watch_pid, args=(args.exit_with_pid,), daemon=True).start()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
