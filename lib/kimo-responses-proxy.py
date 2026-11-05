#!/usr/bin/env python3
"""Local Responses proxy that makes Codex requests acceptable upstream.

Codex 0.164 sends MCP servers (codex_worktrees, plugins) as
{"type":"namespace",...}. xAI, DashScope, QwenCloud and Anthropic reject
that variant with HTTP 422. This proxy rewrites those entries into ordinary
function tools.

The same Codex build puts OpenAI-only controls on hosted web_search:
external_web_access, indexed_web_access, and search_context_size. xAI
rejects each one with HTTP 400
{"code":"400","error":"Argument not supported: external_web_access"},
which fails the turn before the model runs, including a prompt that never
searches. Cached mode is external_web_access false with no indexed gate.
These providers have no cached-only search, so that tool is omitted rather
than turned into a live search. Live and indexed modes keep the tool, with
those keys removed and filters, user_location, and search_content_types
left in place.

The upstream response is streamed unchanged. The API key is not read here.
Codex puts it on the request, and this process only forwards that header.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

# OpenAI Responses controls. xAI returns 400 "Argument not supported" for
# each of these when they appear on a web_search tool.
_WEB_SEARCH_DROPPED_KEYS = (
    "external_web_access",
    "indexed_web_access",
    "search_context_size",
)

PROVIDER_MODELS: dict[str, list[tuple[str, str, int]]] = {
    "dashscope": [
        ("qwen3.8-max", "Qwen 3.8 Max", 1000000),
        ("qwen3.8-flash", "Qwen 3.8 Flash", 1000000),
        ("qwen3.6-flash", "Qwen 3.6 Flash", 1000000),
        ("qwen3-coder-plus", "Qwen 3 Coder Plus", 1000000),
        ("qwen3-coder-turbo", "Qwen 3 Coder Turbo", 1000000),
        ("qwen-plus", "Qwen Plus", 131072),
        ("qwen-turbo", "Qwen Turbo", 131072),
        ("qwen-max", "Qwen Max", 32768),
    ],
    "qwencloud": [
        ("qwen3.8-max", "Qwen 3.8 Max", 1000000),
        ("qwen3.8-flash", "Qwen 3.8 Flash", 1000000),
        ("qwen3-coder-plus", "Qwen 3 Coder Plus", 1000000),
        ("qwen3-coder-turbo", "Qwen 3 Coder Turbo", 1000000),
        ("qwen-plus", "Qwen Plus", 131072),
        ("qwen-turbo", "Qwen Turbo", 131072),
        ("qwen-max", "Qwen Max", 32768),
    ],
    "xai": [
        ("grok-4.7", "Grok 4.7", 500000),
        ("grok-4.6", "Grok 4.6", 500000),
        ("grok-4", "Grok 4", 500000),
        ("grok-beta", "Grok Beta", 131072),
        ("grok-2", "Grok 2", 131072),
    ],
    "anthropic": [
        ("claude-opus-5-5", "Claude Opus 5.5", 1000000),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", 1000000),
        ("claude-3-7-sonnet-latest", "Claude 3.7 Sonnet", 200000),
        ("claude-3-5-sonnet-latest", "Claude 3.5 Sonnet", 200000),
        ("claude-3-5-haiku-latest", "Claude 3.5 Haiku", 200000),
    ],
    "claude": [
        ("claude-opus-5-5", "Claude Opus 5.5", 1000000),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", 1000000),
        ("claude-3-7-sonnet-latest", "Claude 3.7 Sonnet", 200000),
        ("claude-3-5-sonnet-latest", "Claude 3.5 Sonnet", 200000),
        ("claude-3-5-haiku-latest", "Claude 3.5 Haiku", 200000),
    ],
    "gemini": [
        ("gemini-2.5-flash", "Gemini 2.5 Flash", 1000000),
        ("gemini-2.5-pro", "Gemini 2.5 Pro", 1000000),
        ("gemini-2.0-flash", "Gemini 2.0 Flash", 1000000),
        ("gemini-1.5-pro", "Gemini 1.5 Pro", 2000000),
        ("gemini-1.5-flash", "Gemini 1.5 Flash", 1000000),
    ],
}

FALLBACK_MODEL_TEMPLATE: dict = {
    "slug": "test-model",
    "display_name": "Test Model",
    "description": None,
    "default_reasoning_level": "none",
    "supported_reasoning_levels": [
        {"effort": "none", "description": "Turn thinking off"},
        {"effort": "low", "description": "Fast responses with lighter reasoning"},
        {"effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks"},
        {"effort": "high", "description": "Greater reasoning depth for complex problems"},
    ],
    "shell_type": "default",
    "visibility": "list",
    "supported_in_api": True,
    "priority": 0,
    "additional_speed_tiers": [],
    "service_tiers": [],
    "availability_nux": None,
    "upgrade": None,
    "base_instructions": "",
    "model_messages": {
        "instructions_template": "",
        "approvals": None,
        "collaboration_modes": None,
        "auto_review": None,
        "permissions": None,
        "multi_agent": None,
    },
    "include_skills_usage_instructions": False,
    "include_plugin_usage_instructions": False,
    "include_apps_usage_instructions": False,
    "default_reasoning_summary": "auto",
    "support_verbosity": True,
    "default_verbosity": "low",
    "apply_patch_tool_type": None,
    "web_search_tool_type": "text",
    "truncation_policy": {"mode": "tokens", "limit": 10000},
    "supports_image_detail_original": False,
    "context_window": 1000000,
    "effective_context_window_percent": 95,
    "experimental_supported_tools": [],
    "input_modalities": ["text"],
    "supports_search_tool": False,
    "supports_experimental_context": False,
    "use_responses_lite": False,
    "supports_reasoning_effort_updates": False,
    "node_repl_auto_review_required": False,
    "node_repl_disabled": False,
    "supports_parallel_tool_calls": False,
    "supports_reasoning_summaries": False,
}


def _populate_models_cache(catalog_dict: dict) -> None:
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    cache_path = os.path.join(codex_home, "models_cache.json")
    try:
        existing = {}
        if os.path.exists(cache_path):
            try:
                with open(cache_path, "r", encoding="utf-8") as f:
                    existing = json.load(f)
            except Exception:
                existing = {}
        if not isinstance(existing, dict):
            existing = {}
        cached_models = existing.get("models")
        if not isinstance(cached_models, list):
            cached_models = []
        slugs = {m.get("slug") for m in cached_models if isinstance(m, dict)}
        for m in catalog_dict.get("models", []):
            if m.get("slug") not in slugs:
                cached_models.append(m)
                slugs.add(m.get("slug"))
        existing["models"] = cached_models
        existing.setdefault("client_version", "0.164.0")
        if "fetched_at" not in existing:
            existing["fetched_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        os.makedirs(codex_home, exist_ok=True)
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
    except Exception:
        pass


def build_catalog(provider: str, extra_model: str | None = None) -> dict:
    import copy

    key = "xai" if provider == "grok" else provider
    models_spec = list(PROVIDER_MODELS.get(key, []))
    if extra_model and extra_model not in [s for s, _, _ in models_spec]:
        models_spec.insert(0, (extra_model, extra_model, 1000000))
    template = FALLBACK_MODEL_TEMPLATE
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    cache_path = os.path.join(codex_home, "models_cache.json")
    if os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                d = json.load(f)
                if isinstance(d, dict) and d.get("models") and isinstance(d["models"][0], dict):
                    if d["models"][0].get("shell_type") == "default":
                        template = d["models"][0]
        except Exception:
            pass
    catalog = []
    for slug, name, ctx in models_spec:
        m = copy.deepcopy(template)
        m["slug"] = slug
        m["display_name"] = name
        m["description"] = f"{name} via {provider}"
        m["context_window"] = ctx
        m["include_apps_usage_instructions"] = False
        m["include_skills_usage_instructions"] = False
        m["include_plugin_usage_instructions"] = False
        catalog.append(m)
    return {"models": catalog}


def _is_web_search(tool: dict) -> bool:
    kind = tool.get("type")
    return isinstance(kind, str) and (kind == "web_search" or kind.startswith("web_search_"))


def _is_codex_apps(tool: dict) -> bool:
    name = str(tool.get("name") or "")
    server = str(tool.get("server_name") or "")
    connector = str(tool.get("connector_name") or "")
    if server == "codex_apps" or connector == "codex_apps":
        return True
    if name in ("codex_apps", "mcp__codex_apps", "_codex_apps", "mcp_codex_apps"):
        return True
    if name.startswith(("codex_apps__", "mcp__codex_apps__", "_codex_apps__", "mcp_codex_apps__")):
        return True
    if "connector_openai_browser" in name:
        return True
    return False


def prepare_tool(tool: object) -> object | None:
    """Return a tool these providers accept, or None to omit it.

    Drops 'mcp codex_apps' tools for these third-party providers.
    Cached web search is external_web_access false and no indexed gate.
    Keeping that tool would let the provider search the live web, so it is
    dropped. Live and indexed modes stay, without the keys above.
    """
    if not isinstance(tool, dict):
        return tool
    if _is_codex_apps(tool):
        return None
    if not _is_web_search(tool):
        return tool
    if tool.get("external_web_access") is False and tool.get("indexed_web_access") is not True:
        return None
    if not any(key in tool for key in _WEB_SEARCH_DROPPED_KEYS):
        return tool
    cleaned = dict(tool)
    for key in _WEB_SEARCH_DROPPED_KEYS:
        cleaned.pop(key, None)
    return cleaned


def flatten_tools(tools: object) -> list:
    """Expand type=namespace tools into type=function tools."""
    if not isinstance(tools, list):
        return []
    flat: list = []
    for tool in tools:
        if not isinstance(tool, dict) or _is_codex_apps(tool):
            continue
        if tool.get("type") != "namespace":
            prepared = prepare_tool(tool)
            if prepared is not None:
                flat.append(prepared)
            continue
        namespace = str(tool.get("name") or "namespace")
        if _is_codex_apps({"name": namespace}):
            continue
        parent_desc = tool.get("description") if isinstance(tool.get("description"), str) else ""
        for inner in tool.get("tools") or []:
            if not isinstance(inner, dict) or _is_codex_apps(inner):
                continue
            name = inner.get("name")
            function = inner.get("function")
            if not isinstance(name, str) and isinstance(function, dict):
                name = function.get("name")
            if not isinstance(name, str) or not name:
                continue
            rewritten = dict(inner)
            rewritten["type"] = "function"
            rewritten["name"] = f"{namespace}__{name}"
            if _is_codex_apps(rewritten):
                continue
            if parent_desc and not rewritten.get("description"):
                rewritten["description"] = parent_desc
            prepared = prepare_tool(rewritten)
            if prepared is not None:
                flat.append(prepared)
    return flat


def rewrite_body(body: bytes, content_type: str) -> bytes:
    if not body or "json" not in content_type.lower():
        return body
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return body
    if not isinstance(payload, dict) or (
        "tools" not in payload and "tool_choice" not in payload
    ):
        return body
    if "tools" in payload:
        payload["tools"] = flatten_tools(payload.get("tools"))
    choice = payload.get("tool_choice")
    if isinstance(choice, dict):
        if _is_codex_apps(choice):
            payload.pop("tool_choice", None)
        else:
            prepared = prepare_tool(choice)
            if prepared is None:
                payload.pop("tool_choice", None)
            else:
                payload["tool_choice"] = prepared
    elif isinstance(choice, str) and ("codex_apps" in choice):
        payload.pop("tool_choice", None)
    return json.dumps(payload, separators=(",", ":")).encode()


class Proxy(BaseHTTPRequestHandler):
    upstream = ""
    provider: str | None = None
    timeout = 600
    catalog_bytes: bytes | None = None

    def do_POST(self) -> None:
        self._forward()

    def do_GET(self) -> None:
        parts = urlsplit(self.path)
        path = parts.path.rstrip("/")
        if self.catalog_bytes and path in ("/models", "/v1/models"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(self.catalog_bytes)))
            self.end_headers()
            self.wfile.write(self.catalog_bytes)
            self.wfile.flush()
            return
        self._forward()

    def do_DELETE(self) -> None:
        self._forward()

    def _forward(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type", "")
        body = rewrite_body(raw, content_type)
        parts = urlsplit(self.upstream)
        path = self.path
        prefix = "/v1"
        if path == prefix or path.startswith(prefix + "/") or path.startswith(prefix + "?"):
            path = path[len(prefix):] or "/"
        target = parts.path.rstrip("/") + path
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_HEADERS
        }
        headers["Host"] = parts.netloc
        headers["Content-Length"] = str(len(body))
        if self.provider == "xai" or "grok.com" in parts.netloc:
            headers.setdefault("X-Grok-Client-Version", "1.0.70")
        if (parts.hostname or "").endswith("grok.com"):
            # cli-chat-proxy rejects a bare bearer with x_xai_token_auth=none.
            headers["X-XAI-Token-Auth"] = "xai-grok-cli"
            try:
                parsed = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                parsed = None
            if isinstance(parsed, dict) and isinstance(parsed.get("model"), str) and parsed["model"]:
                headers["x-grok-model-override"] = parsed["model"]
        connection_cls = HTTPSConnection if parts.scheme == "https" else HTTPConnection
        port = parts.port or (443 if parts.scheme == "https" else 80)
        try:
            conn = connection_cls(parts.hostname, port, timeout=self.timeout)
            conn.request(self.command, target, body=body, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            message = json.dumps({"error": f"responses proxy: {exc}"}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
            return
        self.send_response(upstream.status)
        for key, value in upstream.getheaders():
            if key.lower() in HOP_HEADERS:
                continue
            self.send_header(key, value)
        self.end_headers()
        while True:
            chunk = upstream.read(8192)
            if not chunk:
                break
            try:
                self.wfile.write(chunk)
                self.wfile.flush()
            except BrokenPipeError:
                break
        conn.close()

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
    parser = argparse.ArgumentParser(description="Flatten Codex namespace tools")
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--exit-with-pid", type=int, required=True)
    parser.add_argument("--provider", default=None)
    parser.add_argument("--model", default=None)
    args = parser.parse_args()
    parts = urlsplit(args.upstream)
    if parts.scheme not in ("https", "http") or not parts.netloc:
        print(f"responses proxy: upstream must be an http(s) URL (got {args.upstream})", file=sys.stderr)
        return 1
    Proxy.upstream = args.upstream.rstrip("/")
    Proxy.provider = args.provider
    if args.provider:
        catalog_dict = build_catalog(args.provider, args.model)
        Proxy.catalog_bytes = json.dumps(catalog_dict).encode("utf-8")
        _populate_models_cache(catalog_dict)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    port = server.server_address[1]
    with open(args.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    threading.Thread(target=_watch_pid, args=(args.exit_with_pid,), daemon=True).start()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
