#!/usr/bin/env python3
"""xAI Grok account inspection, token management and Kimi configuration integration."""

import base64
import datetime
import json
import math
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

EXPIRY_SKEW_SECONDS = 60
BACKUP_KEEP = 5

GROK_MODELS = [
    ("grok-4.7", "Grok 4.7", 500000, 65536, True),
    ("grok-4.6", "Grok 4.6", 500000, 65536, True),
    ("grok-4.5", "Grok 4.5", 256000, 32768, True),
    ("grok-4.3", "Grok 4.3", 256000, 32768, True),
    ("grok-4.20-0309-reasoning", "Grok 4.20 Reasoning", 256000, 32768, True),
    ("grok-4.20-0309-non-reasoning", "Grok 4.20 Non-Reasoning", 256000, 32768, False),
    ("grok-build-0.1", "Grok Build 0.1", 256000, 32768, False),
]


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def grok_dir(home: Path) -> Path:
    configured = os.environ.get("GROK_HOME")
    return Path(configured or home / ".grok")


def auth_file(home: Path) -> Path:
    return grok_dir(home) / "auth.json"


def auth_credentials(home: Path) -> tuple[dict, dict]:
    """Return (whole auth.json document, active entry dict)."""
    f = auth_file(home)
    doc = read_json(f)
    for _k, v in doc.items():
        if isinstance(v, dict) and "key" in v:
            return doc, v
    return doc, {}


def claims(token: str) -> dict:
    try:
        payload = token.split(".")[1]
        value = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return value if isinstance(value, dict) else {}
    except (ValueError, IndexError):
        return {}


def token_expiry(expiry_val_or_token) -> float | None:
    if isinstance(expiry_val_or_token, (int, float)) and not isinstance(expiry_val_or_token, bool):
        if expiry_val_or_token > 1e11:
            return expiry_val_or_token / 1000.0
        return float(expiry_val_or_token)
    if isinstance(expiry_val_or_token, str) and expiry_val_or_token:
        if expiry_val_or_token.startswith("eyJ") and "." in expiry_val_or_token:
            exp = claims(expiry_val_or_token).get("exp")
            if isinstance(exp, (int, float)) and not isinstance(exp, bool) and math.isfinite(exp):
                return float(exp)
        clean = expiry_val_or_token
        if "." in clean:
            prefix, rest = clean.split(".", 1)
            tz_idx = -1
            for idx, c in enumerate(rest):
                if c in ("+", "-", "Z"):
                    tz_idx = idx
                    break
            if tz_idx >= 0:
                frac = rest[:min(tz_idx, 6)]
                tz = rest[tz_idx:]
                clean = f"{prefix}.{frac}{tz}"
            else:
                clean = f"{prefix}.{rest[:6]}"
        try:
            if clean.endswith("Z"):
                clean = clean[:-1] + "+00:00"
            dt = datetime.datetime.fromisoformat(clean)
            return dt.timestamp()
        except Exception:
            pass
    return None


def token_state(home: Path) -> None:
    """Print '<state> <source> <refreshable>'."""
    _doc, entry = auth_credentials(home)
    refresh_token = entry.get("refresh_token")
    refreshable = "yes" if refresh_token else "no"

    env_token = os.environ.get("XAI_AUTH_TOKEN") or ""
    env_key = os.environ.get("XAI_API_KEY") or ""
    file_token = str(entry.get("key") or "")

    if env_token:
        exp = token_expiry(entry.get("expires_at") or file_token) if file_token == env_token else token_expiry(env_token)
        if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid env {refreshable}")
            return
        print(f"expired env {refreshable}")
        return

    if env_key:
        if env_key.startswith("eyJ"):
            exp = token_expiry(env_key)
            if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
                print(f"valid env {refreshable}")
                return
            print(f"expired env {refreshable}")
            return
        elif env_key != "ollama":
            print(f"apikey env {refreshable}")
            return

    if file_token:
        exp = token_expiry(entry.get("expires_at") or file_token)
        if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid file {refreshable}")
            return
        print(f"expired file {refreshable}")
        return

    print(f"missing none {refreshable}")


def read_config(path: Path):
    import tomlkit
    if path.exists():
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    return tomlkit.document()


def prune_backups(config: Path, new_backup: Path) -> None:
    prefix = f"{config.name}.before-grok-"
    parent = config.parent
    existing = sorted(
        [p for p in parent.iterdir() if p.name.startswith(prefix) and not p.is_symlink()],
        key=lambda p: p.stat().st_mtime,
        reverse=True
    )
    for old in existing[BACKUP_KEEP:]:
        try:
            old.unlink()
        except OSError:
            pass


def status(home: Path, config: Path, as_json: bool) -> None:
    gdir = grok_dir(home)
    afile = auth_file(home)
    _doc, entry = auth_credentials(home)

    file_token = str(entry.get("key") or "")
    token = os.environ.get("XAI_AUTH_TOKEN") or (file_token if file_token.startswith("eyJ") else "")
    api_key = os.environ.get("XAI_API_KEY") or ""
    if api_key == "ollama":
        api_key = ""

    exp = token_expiry(entry.get("expires_at") or file_token)
    try:
        expires = (
            datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat()
            if exp
            else (entry.get("expires_at") or "Unknown")
        )
    except (ValueError, OverflowError, OSError):
        expires = entry.get("expires_at") or "Unknown"

    try:
        cfg_doc = read_config(config)
    except (ImportError, OSError, ValueError):
        cfg_doc = {}

    providers = cfg_doc.get("providers", {})
    registered = cfg_doc.get("models", {})
    env = {
        key: "<set>" if os.environ.get(key) else "<unset>"
        for key in ("XAI_AUTH_TOKEN", "XAI_API_KEY", "GROK_AUTH_TOKEN")
    }

    email = entry.get("email")
    team_id = entry.get("team_id")
    user_id = entry.get("user_id")
    auth_mode = entry.get("auth_mode")
    token_valid = (exp > time.time()) if exp is not None else (bool(token) or bool(api_key))

    data = {
        "grok_home": str(gdir),
        "auth_file": str(afile),
        "auth_file_exists": afile.exists(),
        "email": email,
        "team_id": team_id,
        "user_id": user_id,
        "auth_mode": auth_mode,
        "token_present": bool(token) or bool(api_key) or bool(file_token),
        "token_valid": token_valid,
        "token_exp": exp,
        "token_exp_iso": expires,
        "env": env,
        "refreshable": bool(entry.get("refresh_token")),
        "kimi": {
            "config_file": str(config),
            "provider_configured": "xai" in providers,
            "default_model": cfg_doc.get("default_model"),
            "xai_models": [k for k in registered if k.startswith("xai/") or k.startswith("grok/")],
        },
    }

    if as_json:
        print(json.dumps(data, indent=2))
        return

    print("xAI Grok Authentication & Kimi Code Integration")
    print(f"  Grok Home   : {gdir}")
    print(f"  Auth File   : {afile} ({'Found' if afile.exists() else 'Missing'})")
    if email:
        print(f"  Account     : {email}" + (f" (Team: {team_id})" if team_id else ""))
    state = "Active" if token_valid else ("Expired" if exp is not None else "Unknown expiry")
    if token:
        print(f"  OAuth Token : <set> - {state} ({expires})")
    elif api_key:
        print(f"  API Key     : <set> ({api_key[:10]}...)")
    else:
        print("  Session     : <none>")
    print(f"  Refresh Token : {'Present' if data['refreshable'] else 'Absent'}")
    print("  Native authentication: run 'grok' or export XAI_API_KEY")
    for key, val in env.items():
        print(f"    {key} : {val}")
    print(f"  Kimi Config : {config}")
    print(f"    [providers.xai] : {'Configured' if data['kimi']['provider_configured'] else 'Not configured'}"
          f"  ({len(data['kimi']['xai_models'])} models)")
    print(f"    Default Model   : {data['kimi']['default_model'] or '<unset>'}")
    print(f"    xAI/Grok Models : {', '.join(data['kimi']['xai_models']) or '<none>'}")


def get_working_token(home: Path) -> str:
    _doc, entry = auth_credentials(home)
    file_token = str(entry.get("key") or "")
    return (
        os.environ.get("XAI_AUTH_TOKEN")
        or (file_token if file_token.startswith("eyJ") else "")
        or os.environ.get("XAI_API_KEY", "")
        or file_token
    )


def fetch_live_models(token: str, timeout: float = 6) -> list[tuple[str, str, int, int, bool]]:
    if not token or token == "ollama":
        return GROK_MODELS
    endpoints = []
    if token.startswith("eyJ"):
        endpoints.append("https://cli-chat-proxy.grok.com/v1/models")
    endpoints.append("https://api.x.ai/v1/models")
    for url in endpoints:
        headers = {"Authorization": f"Bearer {token}", "User-Agent": "kimo-grok/1.0"}
        if "grok.com" in url:
            headers["X-Grok-Client-Version"] = "1.0.70"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            res = []
            for item in data.get("data", []):
                mid = item.get("id")
                if not mid:
                    continue
                name = item.get("name") or mid
                think = "reasoning" in mid or "4.7" in mid or "4.6" in mid or "4.5" in mid
                ctx = 500000 if ("4.7" in mid or "4.6" in mid) else 256000
                out = 65536 if ("4.7" in mid or "4.6" in mid) else 32768
                res.append((mid, name, ctx, out, think))
            if res:
                return res
        except Exception:
            pass
    return GROK_MODELS


def sync(home: Path, config: Path, selected: str, as_json: bool) -> None:
    import tomlkit
    config.parent.mkdir(parents=True, exist_ok=True)
    doc = read_config(config)

    providers = doc.setdefault("providers", tomlkit.table())
    models = doc.setdefault("models", tomlkit.table())

    p = providers.setdefault("xai", tomlkit.table())
    p["type"] = "openai"
    p["base_url"] = "https://api.x.ai/v1"
    p["api_key_env"] = "XAI_AUTH_TOKEN"
    if "api_key" in p:
        del p["api_key"]

    token = get_working_token(home)
    available_models = fetch_live_models(token)

    for slug, name, ctx, out, think in available_models:
        alias = f"xai/{slug}"
        m = models.setdefault(alias, tomlkit.table())
        m["provider"] = "xai"
        m["model"] = slug
        m["display_name"] = f"{name} (xAI Grok)"
        m["max_context_size"] = ctx
        m["max_output_size"] = out
        caps = ["tool_use"]
        if think:
            caps.append("thinking")
        m["capabilities"] = caps

    if selected:
        target = selected if selected.startswith("xai/") else f"xai/{selected}"
        if target in models:
            doc["default_model"] = target

    # Backup
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S+0000")
    backup = config.parent / f"{config.name}.before-grok-{ts}"
    if config.exists():
        import shutil
        shutil.copy2(config, backup)
        prune_backups(config, backup)

    config.write_text(tomlkit.dumps(doc), encoding="utf-8")
    if as_json:
        print(json.dumps({"ok": True, "provider": "xai", "models": len(available_models)}))
    else:
        print(f"[+] Synchronized {len(available_models)} xAI Grok models into {config}")


def default_model(home: Path, config: Path) -> str:
    try:
        doc = read_config(config)
        default = doc.get("default_model", "")
        if (default.startswith("xai/") or default.startswith("grok/")) and default in doc.get("models", {}):
            return default
    except Exception:
        pass
    return "xai/grok-4.7"


def main():
    if len(sys.argv) < 2:
        action = "status"
    else:
        action = sys.argv[1]

    home = Path(os.environ.get("HOME") or Path.home())
    config = Path(os.environ.get("KIMI_CONFIG") or home / ".kimi-code" / "config.toml")
    as_json = "--json" in sys.argv[2:]
    positional = [a for a in sys.argv[2:] if a != "--json"]
    argument = positional[0] if positional else ""

    if action == "status":
        status(home, config, as_json)
    elif action == "token-state":
        token_state(home)
    elif action == "token":
        tok = get_working_token(home)
        if not tok or tok == "ollama":
            print("Error: No xAI Grok token or API key found. Set XAI_API_KEY or sign in with 'grok login'.", file=sys.stderr)
            sys.exit(1)
        if as_json:
            print(json.dumps({"token": tok}))
        else:
            print(tok)
    elif action == "export":
        tok = get_working_token(home)
        if not tok or tok == "ollama":
            print("Error: No xAI Grok token or API key found. Set XAI_API_KEY or sign in with 'grok login'.", file=sys.stderr)
            sys.exit(1)
        if tok.startswith("xai-"):
            print(f"export XAI_API_KEY={tok}")
        else:
            print(f"export XAI_AUTH_TOKEN={tok}")
            print(f"export XAI_API_KEY={tok}")
    elif action == "sync":
        sync(home, config, argument, as_json)
    elif action == "default-model":
        print(default_model(home, config))
    else:
        raise ValueError(f"unknown action '{action}'")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
