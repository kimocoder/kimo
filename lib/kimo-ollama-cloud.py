#!/usr/bin/env python3
"""Ollama Cloud catalog for Claude Code's /model picker.

`claude-populate` reads {origin}/api/tags and {origin}/api/show, then writes
user settings (CLAUDE_CONFIG_DIR or ~/.claude/settings.json). The API key is
read from OLLAMA_API_KEY and is never accepted on argv or written to disk.

Stdout is one line, "COUNT CTX". COUNT is how many catalog rows this call
wrote (0 when the settings write failed). CTX is the chosen model's window
from the provider, or 0 when the catalog did not say. Exit status is 0 even
when the fetch or the write fails, so a launch can continue.
"""

import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import sys
import tempfile
import urllib.parse
import urllib.request

MARK = "kimo:ollama-cloud"
MODEL_RE = re.compile(r"^[A-Za-z0-9._:/-]+$")
# Claude Code 2.1.321 does not offer a modelPicker row it does not know
# unless behavesAs names a native id. The target changes client handling,
# not the id sent to the provider. 1M maps to the native 1M opus; anything
# smaller maps to haiku, whose window is 200000.
BEHAVES_1M = "claude-opus-4-8"
BEHAVES_DEFAULT = "claude-haiku-4-5"
REQUEST_TIMEOUT = 4
MAX_BODY = 1_000_000
MAX_MODELS = 128
SHOW_WORKERS = 8
# Shown after the context, in this order. "completion" is omitted.
CAP_ORDER = ("tools", "thinking", "vision")


def bearer_from_env() -> str:
    """Return a usable bearer, or "" when the env value must not be sent."""
    key = os.environ.get("OLLAMA_API_KEY") or ""
    if not key or key == "ollama":
        return ""
    if any(ch.isspace() or ord(ch) < 32 for ch in key):
        return ""
    return key


def clean_origin(raw: str) -> str:
    text = (raw or "").strip()
    if not text or any(ch.isspace() for ch in text):
        raise ValueError("origin")
    text = text.rstrip("/")
    parsed = urllib.parse.urlsplit(text)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("origin")
    if parsed.username or parsed.password:
        raise ValueError("origin")
    return text


def fetch(url: str, body: dict | None, key: str) -> object:
    """GET or POST JSON. urllib honors http(s)_proxy; loopback is in no_proxy."""
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if key:
        headers["Authorization"] = "Bearer " + key
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
        raw = response.read(MAX_BODY + 1)
    if len(raw) > MAX_BODY:
        raise ValueError("response too large")
    return json.loads(raw.decode("utf-8"))


def context_length(info: object, model: str) -> int:
    """Pull *.context_length out of /api/show model_info.

    The key is the architecture name, not the tag: gemma4:31b reports
    gemma4.context_length, and clef:27b reports qwen35.context_length.
    One value is used as-is. Several values prefer the longest architecture
    prefix of the tag, so a decoy key cannot win.
    """
    if not isinstance(info, dict):
        return 0
    found: list[tuple[str, int]] = []
    for key, value in info.items():
        if not isinstance(key, str) or not key.endswith("context_length"):
            continue
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            continue
        if key == "context_length":
            prefix = ""
        elif key.endswith(".context_length"):
            prefix = key[: -len(".context_length")]
        else:
            continue
        found.append((prefix, value))
    if not found:
        return 0
    if len(found) == 1:
        return found[0][1]
    model_norm = re.sub(r"[^a-z0-9]", "", model.lower())
    best_len = 0
    best_value = 0
    for prefix, value in found:
        prefix_norm = re.sub(r"[^a-z0-9]", "", prefix.lower())
        if prefix_norm and model_norm.startswith(prefix_norm) and len(prefix_norm) > best_len:
            best_len = len(prefix_norm)
            best_value = value
    return best_value


def capability_text(caps: object) -> str:
    if not isinstance(caps, list):
        return ""
    names: list[str] = []
    for cap in caps:
        if isinstance(cap, str) and cap and cap != "completion" and cap not in names:
            names.append(cap)
    ordered = [cap for cap in CAP_ORDER if cap in names]
    ordered.extend(sorted(cap for cap in names if cap not in CAP_ORDER))
    return ", ".join(ordered)


def describe(model: str, ctx: int, caps: object) -> str:
    parts = [f"{model} via ollama-cloud"]
    if ctx > 0:
        parts.append(f"{ctx} ctx")
    extra = capability_text(caps)
    if extra:
        parts.append(extra)
    return " · ".join(parts)


def behaves_as(ctx: int) -> str:
    if ctx >= 1_000_000:
        return BEHAVES_1M
    return BEHAVES_DEFAULT


def row_for(model: str, ctx: int, caps: object) -> dict:
    return {
        "model": model,
        "label": model,
        "description": describe(model, ctx, caps),
        "behavesAs": behaves_as(ctx),
        "kimo": MARK,
        "ctx": ctx if isinstance(ctx, int) and ctx > 0 else 0,
        "caps": caps if isinstance(caps, list) else [],
    }


def catalog_rows(origin: str, key: str) -> list[dict] | None:
    """Models from the provider, or None when the catalog could not be read."""
    try:
        base = clean_origin(origin)
        doc = fetch(base + "/api/tags", None, key)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None
    raw_models = doc.get("models") if isinstance(doc, dict) else None
    if not isinstance(raw_models, list):
        return None
    rows: list[dict] = []
    seen: set[str] = set()
    for item in raw_models:
        if len(rows) >= MAX_MODELS:
            break
        if isinstance(item, str):
            name = item
            caps: object = []
        elif isinstance(item, dict):
            name = item.get("name") or item.get("model") or ""
            caps = item.get("capabilities")
        else:
            continue
        if not isinstance(name, str) or name in seen or not MODEL_RE.fullmatch(name):
            continue
        seen.add(name)
        rows.append(row_for(name, 0, caps))
    if not rows:
        return rows

    def enrich(item: dict) -> None:
        try:
            shown = fetch(base + "/api/show", {"model": item["model"]}, key)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return
        if not isinstance(shown, dict):
            return
        ctx = context_length(shown.get("model_info"), item["model"])
        if ctx > 0:
            item["ctx"] = ctx
        caps = shown.get("capabilities")
        if isinstance(caps, list) and caps:
            item["caps"] = caps
        item["description"] = describe(item["model"], item["ctx"], item["caps"])
        item["behavesAs"] = behaves_as(item["ctx"])

    workers = min(SHOW_WORKERS, len(rows))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(enrich, rows))
    return rows


def picker_row(item: dict) -> dict:
    return {
        "model": item["model"],
        "label": item["model"],
        "description": item["description"],
        "behavesAs": item["behavesAs"],
        "kimo": MARK,
    }


def write_settings(items: list[dict], replace_owned: bool) -> bool:
    """Merge catalog rows into the user model picker. Never writes an env block."""
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    settings_file = claude_home / "settings.json"
    owned = {item["model"] for item in items}
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
        foreign: list[dict] = []
        previous: list[dict] = []
        raw_options = picker.get("options")
        if isinstance(raw_options, list):
            for opt in raw_options:
                if not isinstance(opt, dict) or not isinstance(opt.get("model"), str):
                    continue
                if opt["model"] in owned:
                    continue
                if opt.get("kimo") == MARK:
                    if not replace_owned:
                        previous.append(opt)
                    continue
                foreign.append(opt)
        picker["options"] = foreign + [picker_row(item) for item in items] + previous
        picker.setdefault("replaceBuiltInOptions", False)
        doc["modelPicker"] = picker

        existing_available = doc.get("availableModels")
        if (
            isinstance(existing_available, list)
            and existing_available
            and all(isinstance(entry, str) and entry in owned for entry in existing_available)
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
        return False
    return True


def populate(origin: str, model: str, fallback_ctx: int) -> tuple[int, int]:
    if not MODEL_RE.fullmatch(model or ""):
        return 0, 0
    if not isinstance(fallback_ctx, int) or isinstance(fallback_ctx, bool) or fallback_ctx <= 0:
        fallback_ctx = 0
    key = bearer_from_env()
    fetched = catalog_rows(origin, key)
    provider_ctx = 0
    if fetched is None:
        items = [row_for(model, fallback_ctx, [])]
        replace_owned = False
    else:
        by_id = {item["model"]: item for item in fetched}
        chosen = by_id.get(model)
        if chosen is None:
            items = [row_for(model, fallback_ctx, [])] + fetched
        else:
            provider_ctx = chosen["ctx"] if isinstance(chosen.get("ctx"), int) else 0
            items = sorted(fetched, key=lambda item: 0 if item["model"] == model else 1)
        replace_owned = True
    if not write_settings(items, replace_owned):
        return 0, provider_ctx
    return len(items), provider_ctx


def parse_args(argv: list[str]) -> tuple[str, str, int]:
    origin = ""
    model = ""
    context = 0
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag not in {"--origin", "--model", "--context"} or index + 1 >= len(argv):
            raise ValueError("args")
        value = argv[index + 1]
        index += 2
        if flag == "--origin":
            origin = value
        elif flag == "--model":
            model = value
        elif value.isdigit() and int(value) > 0:
            context = int(value)
        else:
            raise ValueError("context")
    if not origin or not model:
        raise ValueError("args")
    return origin, model, context


def main(argv: list[str]) -> int:
    try:
        if not argv or argv[0] != "claude-populate":
            print("0 0")
            return 0
        origin, model, fallback = parse_args(argv[1:])
        count, ctx = populate(origin, model, fallback)
        print(f"{count} {ctx}")
    except Exception:
        print("0 0")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
