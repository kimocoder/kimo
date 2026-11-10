#!/usr/bin/env python3
"""xAI Grok account inspection, token management and Kimi configuration integration."""

import base64
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

EXPIRY_SKEW_SECONDS = 60
BACKUP_KEEP = 5
# Public OIDC token endpoint discovered from https://auth.x.ai/.well-known/openid-configuration.
# A grok-login session refreshes here with the refresh_token stored in auth.json.
GROK_TOKEN_URL = "https://auth.x.ai/oauth2/token"  # nosec B105 - an endpoint, not a secret

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


def session_fresh(token: str) -> bool | None:
    """True when a JWT is still usable, False when it is expired, None otherwise.

    A token with no exp claim is treated as usable. cli-chat-proxy rejects an
    expired one with 401 reason=no auth context even when X-XAI-Token-Auth is set.
    """
    if not token.startswith("eyJ"):
        return None
    exp = token_expiry(token)
    if exp is None:
        return True
    return exp > time.time() + EXPIRY_SKEW_SECONDS


def token_state(home: Path) -> None:
    """Print '<state> <source> <refreshable>'.

    An expired JWT exported in the environment must not hide a still-valid
    session in auth.json. That stale bearer is what cli-chat-proxy reports as
    auth_kind=bearer, x_xai_token_auth=xai-grok-cli, reason=no auth context.
    """
    _doc, entry = auth_credentials(home)
    refreshable = "yes" if entry.get("refresh_token") else "no"
    env_auth = os.environ.get("XAI_AUTH_TOKEN") or ""
    env_key = os.environ.get("XAI_API_KEY") or ""
    if env_key == "ollama":
        env_key = ""
    file_token = str(entry.get("key") or "")
    if not file_token.startswith("eyJ"):
        file_token = ""

    for token in (env_auth, env_key):
        if session_fresh(token) is True:
            print(f"valid env {refreshable}")
            return
    # A real xai- key is a different credential from the grok-login session.
    if env_key and not env_key.startswith("eyJ"):
        print(f"apikey env {refreshable}")
        return
    if session_fresh(file_token) is True:
        print(f"valid file {refreshable}")
        return
    if session_fresh(env_auth) is False or session_fresh(env_key) is False:
        print(f"expired env {refreshable}")
        return
    if file_token:
        print(f"expired file {refreshable}")
        return
    print(f"missing none {refreshable}")


def _active_entry(doc: dict) -> tuple[str, dict]:
    for key, value in doc.items():
        if isinstance(value, dict) and "key" in value:
            return key, value
    return "", {}


def oidc_client_id(entry_key: str, entry: dict, token: str) -> str:
    client = entry.get("oidc_client_id")
    if isinstance(client, str) and client:
        return client
    if "::" in entry_key:
        tail = entry_key.split("::", 1)[1]
        if tail:
            return tail
    audience = claims(token).get("aud")
    if isinstance(audience, str) and audience:
        return audience
    if isinstance(audience, list) and audience and isinstance(audience[0], str):
        return audience[0]
    return ""


def write_auth(home: Path, doc: dict) -> None:
    """Atomically replace auth.json, owner-only.

    No backup: the document holds a live refresh token. Unknown keys are kept
    because the parsed document is updated, not rebuilt.
    """
    path = auth_file(home)
    if path.is_symlink():
        raise ValueError(f"Refusing to replace a symlinked {path}.")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(doc, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def _token_url_allowed(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https":
        return True
    return parts.scheme == "http" and parts.hostname in ("127.0.0.1", "::1", "localhost")


def refresh(home: Path) -> None:
    """Renew the grok-login access token from auth.json's refresh_token.

    Refresh tokens rotate. Renewals are serialized so two launches do not
    present the same grant.
    """
    gdir = grok_dir(home)
    gdir.mkdir(parents=True, exist_ok=True)
    timeout = float(os.environ.get("KIMO_GROK_REFRESH_TIMEOUT") or 30)
    runtime = os.environ.get("KIMO_RUNTIME_DIR") or ""
    key = hashlib.sha256(str(gdir.resolve()).encode()).hexdigest()[:16]
    lock_path = (Path(runtime) if os.path.isdir(runtime) else gdir) / f".grok-auth-{key}.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        deadline = time.monotonic() + timeout + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise ValueError("Another kimo process is renewing the xAI Grok token; retry.") from None
                time.sleep(0.1)
        _doc, entry = auth_credentials(home)
        current = str(entry.get("key") or "")
        if session_fresh(current) is True:
            print(f"  [✓] The xAI Grok token in {auth_file(home)} was already renewed.", file=sys.stderr)
            return
        _refresh_locked(home, timeout)


def _refresh_locked(home: Path, timeout: float) -> None:
    doc = read_json(auth_file(home))
    entry_key, entry = _active_entry(doc)
    if not entry_key:
        raise ValueError(f"No session in {auth_file(home)}; sign in with 'grok login'.")
    refresh_token = entry.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        raise ValueError(f"No refresh_token in {auth_file(home)}; sign in again with 'grok login'.")
    current = str(entry.get("key") or "")
    client = oidc_client_id(entry_key, entry, current)
    if not client:
        raise ValueError(f"No OIDC client id in {auth_file(home)}; sign in again with 'grok login'.")
    url = os.environ.get("KIMO_GROK_TOKEN_URL") or GROK_TOKEN_URL
    if not _token_url_allowed(url):
        raise ValueError(f"Refusing to send the refresh token to {url!r}: use an https:// URL.")
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client,
    }).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310 - scheme checked above
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            error.read()
        except OSError:
            pass
        # The response body is not surfaced: it can echo the grant it rejected.
        raise ValueError(
            f"xAI OIDC refresh was refused (HTTP {error.code}). Sign in again with 'grok login'.") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
        raise ValueError(f"xAI OIDC refresh failed: {error}") from None
    if not isinstance(payload, dict):
        raise ValueError("xAI OIDC refresh returned a malformed response.")
    access = payload.get("access_token")
    if not isinstance(access, str) or not access:
        raise ValueError("xAI OIDC refresh returned no access_token.")
    entry["key"] = access
    rotated = payload.get("refresh_token")
    if isinstance(rotated, str) and rotated:
        entry["refresh_token"] = rotated
    exp = token_expiry(access)
    if exp is None:
        expires_in = payload.get("expires_in")
        if isinstance(expires_in, (int, float)) and not isinstance(expires_in, bool) and math.isfinite(expires_in):
            exp = time.time() + float(expires_in)
    if exp is not None:
        try:
            entry["expires_at"] = datetime.datetime.fromtimestamp(
                exp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (ValueError, OverflowError, OSError):
            pass
    doc[entry_key] = entry
    write_auth(home, doc)
    until = ""
    if exp is not None:
        try:
            until = f" (expires {datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat(timespec='seconds')})"
        except (ValueError, OverflowError, OSError):
            until = ""
    print(f"  [✓] Refreshed the xAI Grok token in {auth_file(home)}{until}", file=sys.stderr)


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
    """Prefer a still-valid session over an expired JWT left in the environment."""
    _doc, entry = auth_credentials(home)
    file_token = str(entry.get("key") or "")
    if not file_token.startswith("eyJ"):
        file_token = ""
    env_auth = os.environ.get("XAI_AUTH_TOKEN") or ""
    env_key = os.environ.get("XAI_API_KEY") or ""
    if env_key == "ollama":
        env_key = ""
    for token in (env_auth, env_key):
        if session_fresh(token) is True:
            return token
    if env_key and not env_key.startswith("eyJ"):
        return env_key
    if session_fresh(file_token) is True:
        return file_token
    return env_auth or file_token or env_key


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
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec B310
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


def sync(home: Path, config: Path, selected: str, as_json: bool, context_override: int | None = None) -> None:
    import tomlkit
    config.parent.mkdir(parents=True, exist_ok=True)
    doc = read_config(config)

    providers = doc.setdefault("providers", tomlkit.table())
    models = doc.setdefault("models", tomlkit.table())

    p = providers.setdefault("xai", tomlkit.table())
    p["type"] = "openai"
    base = os.environ.get("KIMO_XAI_BASE_URL") or "https://api.x.ai/v1"
    p["base_url"] = base.rstrip("/")
    token = get_working_token(home)
    if token.startswith("xai-"):
        p["api_key_env"] = "XAI_API_KEY"
    else:
        p["api_key_env"] = "XAI_AUTH_TOKEN"
    if "api_key" in p:
        del p["api_key"]

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

    target = ""
    if selected:
        target = selected if selected.startswith("xai/") else f"xai/{selected.removeprefix('grok/')}"
        if target not in models:
            slug = target.removeprefix("xai/")
            m = models.setdefault(target, tomlkit.table())
            m["provider"] = "xai"
            m["model"] = slug
            m["display_name"] = f"{slug} (xAI Grok)"
            m["max_context_size"] = context_override or 500000
            m["max_output_size"] = 65536
            m["capabilities"] = ["tool_use", "thinking"]
        doc["default_model"] = target

    if context_override is not None:
        if target and target in models:
            models[target]["max_context_size"] = context_override
        else:
            for k, m in models.items():
                if k.startswith("xai/"):
                    m["max_context_size"] = context_override

    # Backup
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S+0000")
    backup = config.parent / f"{config.name}.before-grok-{ts}"
    if config.exists():
        import shutil
        shutil.copy2(config, backup)
        prune_backups(config, backup)

    config.write_text(tomlkit.dumps(doc), encoding="utf-8")
    selected_ctx = models.get(target, {}).get("max_context_size") if target else (
        context_override or (models.get(doc.get("default_model", ""), {}).get("max_context_size") or 500000)
    )
    if as_json:
        print(json.dumps({
            "ok": True,
            "provider": "xai",
            "models": len([k for k in models if k.startswith("xai/")]),
            "default_model": doc.get("default_model"),
            "max_context_size": selected_ctx,
        }))
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
    context_override = None
    args = sys.argv[2:]
    for i, a in enumerate(args):
        if a == "--ctx" and i + 1 < len(args):
            try:
                context_override = int(args[i + 1])
            except ValueError:
                pass
    positional = [a for i, a in enumerate(args) if a != "--json" and a != "--ctx" and (i == 0 or args[i - 1] != "--ctx")]
    argument = positional[0] if positional else ""

    if action == "status":
        status(home, config, as_json)
    elif action == "token-state":
        token_state(home)
    elif action == "refresh":
        refresh(home)
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
        sync(home, config, argument, as_json, context_override=context_override)
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
