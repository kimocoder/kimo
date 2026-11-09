#!/usr/bin/env python3
"""Claude account inspection, OAuth refresh and Kimi configuration integration."""

import base64
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"  # nosec B105
EXPIRY_SKEW_SECONDS = 60
BACKUP_KEEP = 5

CLAUDE_MODELS = [
    ("claude-opus-5-5", "Claude Opus 5.5", 1000000, 65536, True),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5", 1000000, 65536, True),
    ("claude-3-7-sonnet-latest", "Claude 3.7 Sonnet", 200000, 65536, True),
    ("claude-3-5-sonnet-latest", "Claude 3.5 Sonnet", 200000, 8192, False),
    ("claude-3-5-haiku-latest", "Claude 3.5 Haiku", 200000, 8192, False),
]


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def claude_dir(home: Path) -> Path:
    secure = os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
    configured = secure if secure is not None else os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(configured or home / ".claude")


def auth_credentials(home: Path) -> tuple[dict, dict]:
    """Return (credentials document, claudeAiOauth mapping)."""
    creds_file = claude_dir(home) / ".credentials.json"
    doc = read_json(creds_file)
    oauth = doc.get("claudeAiOauth")
    return doc, (oauth if isinstance(oauth, dict) else {})


def write_credentials(home: Path, doc: dict) -> None:
    """Atomically write credentials document at mode 0600."""
    creds_file = claude_dir(home) / ".credentials.json"
    creds_file.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=creds_file.name + ".", dir=creds_file.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(doc, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, creds_file)
    finally:
        if os.path.exists(temp):
            try:
                os.unlink(temp)
            except OSError:
                pass


def claims(token: str) -> dict:
    try:
        payload = token.split(".")[1]
        value = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return value if isinstance(value, dict) else {}
    except (ValueError, IndexError):
        return {}


def token_expiry(token_or_ms) -> float | None:
    if isinstance(token_or_ms, (int, float)) and not isinstance(token_or_ms, bool):
        # Expiration in ms since epoch
        if token_or_ms > 1e11:
            return token_or_ms / 1000.0
        return float(token_or_ms)
    if isinstance(token_or_ms, str) and "." in token_or_ms:
        exp = claims(token_or_ms).get("exp")
        if isinstance(exp, (int, float)) and not isinstance(exp, bool) and math.isfinite(exp):
            return float(exp)
    return None


def token_state(home: Path) -> None:
    """Print '<state> <source> <refreshable>'.

    state: valid / expired / apikey / missing
    source: env / file / none
    refreshable: yes / no
    """
    _, oauth = auth_credentials(home)
    refreshable = "yes" if oauth.get("refreshToken") else "no"
    state = "missing"

    env_token = (
        os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        or os.environ.get("ANTHROPIC_AUTH_TOKEN")
        or ""
    )
    file_token = str(oauth.get("accessToken") or "")
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")

    candidates = [("env", env_token), ("file", file_token)]
    for source, token in candidates:
        if not token:
            continue
        if token.startswith("sk-ant-api") or token.startswith("sk-ant-live"):
            state = "apikey"
            continue
        exp = token_expiry(oauth.get("expiresAt") if source == "file" else token)
        if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid {source} {refreshable}")
            return
        state = "expired"

    if api_key and (api_key.startswith("sk-ant-api") or api_key.startswith("sk-ant-live")):
        print(f"apikey env {refreshable}")
        return

    print(f"{state} none {refreshable}")


def refresh(home: Path) -> None:
    """Renew the Claude OAuth token from .credentials.json's refreshToken."""
    cdir = claude_dir(home)
    cdir.mkdir(parents=True, exist_ok=True)
    timeout = float(os.environ.get("KIMO_CLAUDE_REFRESH_TIMEOUT") or 30)

    runtime = os.environ.get("KIMO_RUNTIME_DIR") or ""
    key = hashlib.sha256(str(cdir.resolve()).encode()).hexdigest()[:16]
    lock_path = (Path(runtime) if os.path.isdir(runtime) else cdir) / f".claude-auth-{key}.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        deadline = time.monotonic() + timeout + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise ValueError("Another kimo process is renewing the Claude OAuth token; retry.") from None
                time.sleep(0.1)

        doc, oauth = auth_credentials(home)
        cur_exp = token_expiry(oauth.get("expiresAt"))
        if cur_exp is not None and cur_exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"  [✓] The Claude OAuth token in {cdir / '.credentials.json'} was already renewed.", file=sys.stderr)
            return
        _refresh_locked(home, timeout)


def _refresh_locked(home: Path, timeout: float) -> None:
    cdir = claude_dir(home)
    doc, oauth = auth_credentials(home)
    refresh_token = oauth.get("refreshToken")
    if not isinstance(refresh_token, str) or not refresh_token:
        raise ValueError(f"No refreshToken in {cdir / '.credentials.json'}; sign in with 'claude auth login'.")

    url = os.environ.get("KIMO_CLAUDE_TOKEN_URL") or CLAUDE_TOKEN_URL
    parts = urllib.parse.urlsplit(url)
    if not (parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in ("127.0.0.1", "::1", "localhost"))):
        raise ValueError(f"Refusing to send refresh token to {url!r}: use an https:// URL.")

    client_id = oauth.get("clientId") or os.environ.get("CLAUDE_CODE_OAUTH_CLIENT_ID") or CLAUDE_CLIENT_ID
    body_dict = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }
    scopes = oauth.get("scopes")
    if isinstance(scopes, list) and scopes and all(isinstance(s, str) for s in scopes):
        body_dict["scope"] = " ".join(scopes)

    body = json.dumps(body_dict).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ValueError(f"Claude OAuth refresh was refused (HTTP {error.code}). Sign in with 'claude auth login'.") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
        raise ValueError(f"Claude OAuth refresh failed: {error}") from None

    if not isinstance(payload, dict):
        raise ValueError("Claude OAuth refresh returned a malformed response.")
    access = payload.get("access_token")
    if not isinstance(access, str) or not access:
        raise ValueError("Claude OAuth refresh returned no access_token.")

    oauth["accessToken"] = access
    if "expires_in" in payload:
        try:
            oauth["expiresAt"] = int(time.time() * 1000 + float(payload["expires_in"]) * 1000)
        except (ValueError, TypeError):
            pass
    if isinstance(payload.get("refresh_token"), str) and payload["refresh_token"]:
        oauth["refreshToken"] = payload["refresh_token"]

    doc["claudeAiOauth"] = oauth
    write_credentials(home, doc)

    exp = token_expiry(oauth.get("expiresAt"))
    until = ""
    if exp is not None:
        try:
            until = f" (expires {datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat(timespec='seconds')})"
        except (ValueError, OverflowError, OSError):
            until = ""
    print(f"  [✓] Refreshed the Claude OAuth token in {cdir / '.credentials.json'}{until}", file=sys.stderr)


def read_config(path: Path):
    import tomlkit
    if path.exists():
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    return tomlkit.document()


def prune_backups(config: Path, keep_path: Path) -> None:
    backups = []
    for path in config.parent.glob(config.name + ".before-claude-*"):
        try:
            info = path.lstat()
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode):
            backups.append((info.st_mtime, str(path)))
    backups.sort(reverse=True)
    for _, path in backups[BACKUP_KEEP:]:
        if path == str(keep_path):
            continue
        try:
            os.unlink(path)
        except OSError:
            pass


def status(home: Path, config: Path, as_json: bool) -> None:
    cdir = claude_dir(home)
    creds_file = cdir / ".credentials.json"
    doc, oauth = auth_credentials(home)

    token = (
        os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        or os.environ.get("ANTHROPIC_AUTH_TOKEN")
        or str(oauth.get("accessToken") or "")
    )
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")

    exp = token_expiry(oauth.get("expiresAt") or token)
    try:
        expires = datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat() if exp else "Unknown"
    except (ValueError, OverflowError, OSError):
        expires = "Unknown"

    try:
        cfg_doc = read_config(config)
    except (ImportError, OSError, ValueError):
        cfg_doc = {}

    providers = cfg_doc.get("providers", {})
    registered = cfg_doc.get("models", {})
    env = {
        key: "<set>" if os.environ.get(key) else "<unset>"
        for key in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY")
    }

    sub_type = oauth.get("subscriptionType") or ("api_key" if api_key else None)
    rate_tier = oauth.get("rateLimitTier")

    token_valid = (exp > time.time()) if exp is not None else (bool(token) or bool(api_key))

    data = {
        "claude_home": str(cdir),
        "auth_file": str(creds_file),
        "auth_file_exists": creds_file.exists(),
        "subscription_type": sub_type,
        "rate_limit_tier": rate_tier,
        "token_present": bool(token) or bool(api_key),
        "token_valid": token_valid,
        "token_exp": exp,
        "token_exp_iso": expires,
        "env": env,
        "refreshable": bool(oauth.get("refreshToken")),
        "kimi": {
            "config_file": str(config),
            "provider_configured": "anthropic" in providers,
            "default_model": cfg_doc.get("default_model"),
            "anthropic_models": [k for k in registered if k.startswith("anthropic/")],
        },
    }

    if as_json:
        print(json.dumps(data, indent=2))
        return

    print("Claude Authentication & Kimi Code Integration")
    print(f"  Claude Home : {cdir}")
    print(f"  Auth File   : {creds_file} ({'Found' if creds_file.exists() else 'Missing'})")
    if sub_type:
        print(f"  Plan/Tier   : {sub_type}" + (f" ({rate_tier})" if rate_tier else ""))
    state = "Active" if token_valid else ("Expired" if exp is not None else "Unknown expiry")
    if token:
        print(f"  OAuth Token : <set> - {state} ({expires})")
    elif api_key:
        print(f"  API Key     : <set> ({api_key[:10]}...)")
    else:
        print("  Session     : <none>")
    print(f"  Refresh Token : {'Present' if data['refreshable'] else 'Absent'}")
    if state == "Expired" and data["refreshable"]:
        print("                  'kimo claude --token' renews it automatically.")
    print("  Native authentication: run 'kimo claude auth login'")
    for key, val in env.items():
        print(f"    {key} : {val}")
    print(f"  Kimi Config : {config}")
    print(f"    [providers.anthropic] : {'Configured' if data['kimi']['provider_configured'] else 'Not configured'}"
          f"  ({len(data['kimi']['anthropic_models'])} models)")
    print(f"    Default Model : {data['kimi']['default_model'] or '<unset>'}")
    print(f"    Claude Models : {', '.join(data['kimi']['anthropic_models']) or '<none>'}")


def get_working_token(home: Path) -> str:
    doc, oauth = auth_credentials(home)
    exp = token_expiry(oauth.get("expiresAt"))
    if exp is not None and exp <= time.time() + EXPIRY_SKEW_SECONDS and oauth.get("refreshToken"):
        if os.environ.get("KIMO_CLAUDE_NO_REFRESH") != "1":
            try:
                refresh(home)
                doc, oauth = auth_credentials(home)
            except Exception:
                pass
    return (
        os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        or os.environ.get("ANTHROPIC_AUTH_TOKEN")
        or str(oauth.get("accessToken") or "")
        or os.environ.get("ANTHROPIC_API_KEY", "")
    )


def fetch_live_models(token: str, timeout: float = 10) -> list[tuple[str, str, int, int, bool]]:
    if not token:
        return CLAUDE_MODELS
    is_oauth = token.startswith("sk-ant-oat") or ("." in token and not token.startswith("sk-"))
    headers = {"anthropic-version": "2023-06-01", "User-Agent": "kimo-claude/1.0"}
    if is_oauth:
        headers["Authorization"] = f"Bearer {token}"
        headers["anthropic-beta"] = "oauth-2025-04-20"
    else:
        headers["x-api-key"] = token
    req = urllib.request.Request("https://api.anthropic.com/v1/models", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec B310
            data = json.loads(resp.read().decode("utf-8"))
        res = []
        for item in data.get("data", []):
            mid = item.get("id")
            if not mid:
                continue
            name = item.get("display_name") or mid
            ctx = item.get("max_input_tokens") or 200000
            out = item.get("max_tokens") or 8192
            think = bool((item.get("capabilities") or {}).get("thinking", {}).get("supported"))
            res.append((mid, name, ctx, out, think))
        if res:
            return res
    except Exception:
        pass
    return CLAUDE_MODELS


def list_models(home: Path, as_json: bool) -> None:
    token = get_working_token(home)
    if not token:
        print("Error: No Claude token or Anthropic API key found. Run 'kimo claude auth login'.", file=sys.stderr)
        sys.exit(1)
    models = fetch_live_models(token)
    if as_json:
        result = [
            {"model": m[0], "display_name": m[1], "max_context_size": m[2],
             "max_output_size": m[3], "thinking": m[4]}
            for m in models
        ]
        print(json.dumps(result, indent=2))
        return
    print(f"{'MODEL':<32} {'DISPLAY NAME':<26} {'CONTEXT':>9} {'MAX OUT':>8} {'THINKING':>9}")
    print("-" * 88)
    for slug, name, ctx, out, think in models:
        t_str = "yes" if think else "no"
        print(f"{slug:<32} {name:<26} {ctx:>9} {out:>8} {t_str:>9}")


def sync(home: Path, config: Path, selected: str, as_json: bool) -> None:
    import tomlkit
    config.parent.mkdir(parents=True, exist_ok=True)
    doc = read_config(config)

    providers = doc.setdefault("providers", tomlkit.table())
    models = doc.setdefault("models", tomlkit.table())

    p = providers.setdefault("anthropic", tomlkit.table())
    p["type"] = "anthropic"
    p["base_url"] = "https://api.anthropic.com"
    p["api_key_env"] = "ANTHROPIC_AUTH_TOKEN"

    token = get_working_token(home)
    available_models = fetch_live_models(token)

    for slug, name, ctx, out, think in available_models:
        alias = f"anthropic/{slug}"
        m = models.setdefault(alias, tomlkit.table())
        m["provider"] = "anthropic"
        m["model"] = slug
        m["display_name"] = f"{name} (Anthropic)"
        m["max_context_size"] = ctx
        m["max_output_size"] = out
        caps = ["tool_use"]
        if think:
            caps.append("thinking")
        m["capabilities"] = caps

    if selected:
        target = selected if selected.startswith("anthropic/") else f"anthropic/{selected}"
        if target in models:
            doc["default_model"] = target

    # Make backup
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S+0000")
    backup = config.parent / f"{config.name}.before-claude-{ts}"
    if config.exists():
        import shutil
        shutil.copy2(config, backup)
        prune_backups(config, backup)

    config.write_text(tomlkit.dumps(doc), encoding="utf-8")
    if as_json:
        print(json.dumps({"ok": True, "provider": "anthropic", "models": len(available_models)}))
    else:
        print(f"[+] Synchronized {len(available_models)} Claude models into {config}")


def default_model(home: Path, config: Path) -> str:
    try:
        doc = read_config(config)
        default = doc.get("default_model", "")
        if default.startswith("anthropic/") and default in doc.get("models", {}):
            return default
    except Exception:
        pass
    return "anthropic/claude-opus-5-5"


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
        doc, oauth = auth_credentials(home)
        exp = token_expiry(oauth.get("expiresAt"))
        if exp is not None and exp <= time.time() + EXPIRY_SKEW_SECONDS and oauth.get("refreshToken"):
            if os.environ.get("KIMO_CLAUDE_NO_REFRESH") != "1":
                refresh(home)
                doc, oauth = auth_credentials(home)
        tok = (
            os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
            or os.environ.get("ANTHROPIC_AUTH_TOKEN")
            or str(oauth.get("accessToken") or "")
            or os.environ.get("ANTHROPIC_API_KEY", "")
        )
        if not tok:
            print("Error: No Claude token or Anthropic API key found. Run 'kimo claude auth login'.", file=sys.stderr)
            sys.exit(1)
        if as_json:
            print(json.dumps({"token": tok}))
        else:
            print(tok)
    elif action == "export":
        doc, oauth = auth_credentials(home)
        exp = token_expiry(oauth.get("expiresAt"))
        if exp is not None and exp <= time.time() + EXPIRY_SKEW_SECONDS and oauth.get("refreshToken"):
            if os.environ.get("KIMO_CLAUDE_NO_REFRESH") != "1":
                refresh(home)
                doc, oauth = auth_credentials(home)
        tok = (
            os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
            or os.environ.get("ANTHROPIC_AUTH_TOKEN")
            or str(oauth.get("accessToken") or "")
            or os.environ.get("ANTHROPIC_API_KEY", "")
        )
        if not tok:
            print("Error: No Claude token or Anthropic API key found. Run 'kimo claude auth login'.", file=sys.stderr)
            sys.exit(1)
        if tok.startswith("sk-ant-api") or tok.startswith("sk-ant-live"):
            print(f"export ANTHROPIC_API_KEY={tok}")
        else:
            print(f"export CLAUDE_CODE_OAUTH_TOKEN={tok}")
            print(f"export ANTHROPIC_AUTH_TOKEN={tok}")
    elif action == "refresh":
        refresh(home)
    elif action in ("models", "list", "ls"):
        list_models(home, as_json)
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
