#!/usr/bin/env python3
"""Gemini / Google account inspection, OAuth refresh and token management."""

import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

EXPIRY_SKEW_SECONDS = 60
GEMINI_TOKEN_URL = "https://oauth2.googleapis.com/token"  # nosec B105
BACKUP_KEEP = 5

# Common Gemini models
GEMINI_MODELS = [
    ("gemini-2.5-flash", "Gemini 2.5 Flash", 1048576, 65536, True),
    ("gemini-2.5-pro", "Gemini 2.5 Pro", 1048576, 65536, True),
    ("gemini-2.0-flash", "Gemini 2.0 Flash", 1048576, 8192, True),
    ("gemini-1.5-pro", "Gemini 1.5 Pro", 2097152, 8192, True),
    ("gemini-1.5-flash", "Gemini 1.5 Flash", 1048576, 8192, True),
]


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def gemini_dir(home: Path) -> Path:
    configured = os.environ.get("GEMINI_HOME")
    return Path(configured or home / ".gemini")


def auth_token_file(home: Path) -> Path:
    gdir = gemini_dir(home)
    p1 = gdir / "antigravity-cli" / "antigravity-oauth-token"
    if p1.exists():
        return p1
    p2 = gdir / "gemini-credentials.json"
    if p2.exists():
        return p2
    return p1


def parse_expiry(expiry_val) -> float | None:
    if isinstance(expiry_val, (int, float)) and not isinstance(expiry_val, bool):
        if expiry_val > 1e11:
            return expiry_val / 1000.0
        return float(expiry_val)
    if isinstance(expiry_val, str) and expiry_val:
        # ISO string like '2026-10-27T17:52:35.645492588+01:00'
        clean = expiry_val
        # Python fromisoformat before 3.11 doesn't support nanoseconds; truncate fractional seconds to 6 digits
        if "." in clean:
            prefix, rest = clean.split(".", 1)
            # Find timezone separator (+ or - or Z)
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
            dt = datetime.datetime.fromisoformat(clean)
            return dt.timestamp()
        except Exception:
            pass
    return None


def write_token_file(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            try:
                os.unlink(temp)
            except OSError:
                pass


def token_state(home: Path) -> None:
    """Print '<state> <source> <refreshable>'."""
    tpath = auth_token_file(home)
    doc = read_json(tpath)
    tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
    refresh_token = tok_obj.get("refresh_token")
    refreshable = "yes" if refresh_token else "no"

    env_token = (
        os.environ.get("GEMINI_AUTH_TOKEN")
        or os.environ.get("GOOGLE_OAUTH_TOKEN")
        or ""
    )
    env_key = (
        os.environ.get("GEMINI_API_KEY")
        or os.environ.get("GOOGLE_API_KEY")
        or ""
    )
    file_token = str(tok_obj.get("access_token") or "")

    if env_token:
        exp = parse_expiry(tok_obj.get("expiry")) if file_token == env_token else None
        if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid env {refreshable}")
            return
        print(f"expired env {refreshable}")
        return

    if file_token:
        exp = parse_expiry(tok_obj.get("expiry"))
        if exp is None or exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid file {refreshable}")
            return
        print(f"expired file {refreshable}")
        return

    if env_key and env_key != "ollama":
        print(f"apikey env {refreshable}")
        return

    print(f"missing none {refreshable}")


def refresh(home: Path) -> None:
    gdir = gemini_dir(home)
    gdir.mkdir(parents=True, exist_ok=True)
    timeout = float(os.environ.get("KIMO_GEMINI_REFRESH_TIMEOUT") or 30)

    runtime = os.environ.get("KIMO_RUNTIME_DIR") or ""
    key = hashlib.sha256(str(gdir.resolve()).encode()).hexdigest()[:16]
    lock_path = (Path(runtime) if os.path.isdir(runtime) else gdir) / f".gemini-auth-{key}.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        deadline = time.monotonic() + timeout + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise ValueError("Another kimo process is renewing the Gemini OAuth token; retry.") from None
                time.sleep(0.1)

        tpath = auth_token_file(home)
        doc = read_json(tpath)
        tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
        cur_exp = parse_expiry(tok_obj.get("expiry"))
        if cur_exp is not None and cur_exp > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"  [✓] The Gemini OAuth token in {tpath} was already renewed.", file=sys.stderr)
            return
        _refresh_locked(home, timeout)


def _refresh_locked(home: Path, timeout: float) -> None:
    tpath = auth_token_file(home)
    doc = read_json(tpath)
    tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
    refresh_token = tok_obj.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        raise ValueError(f"No refresh_token in {tpath}; sign in with 'agy' or provide GEMINI_API_KEY.")

    url = os.environ.get("KIMO_GEMINI_TOKEN_URL") or GEMINI_TOKEN_URL
    parts = urllib.parse.urlsplit(url)
    if not (parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in ("127.0.0.1", "::1", "localhost"))):
        raise ValueError(f"Refusing to send refresh token to {url!r}: use an https:// URL.")

    client_id = os.environ.get("GOOGLE_OAUTH_CLIENT_ID") or tok_obj.get("client_id") or ""
    client_secret = os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET") or tok_obj.get("client_secret") or ""

    post_data = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }
    if client_id:
        post_data["client_id"] = client_id
    if client_secret:
        post_data["client_secret"] = client_secret

    encoded = urllib.parse.urlencode(post_data).encode("utf-8")
    request = urllib.request.Request(
        url, data=encoded, method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ValueError(f"Gemini OAuth refresh was refused (HTTP {error.code}). Re-authenticate via 'agy'.") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
        raise ValueError(f"Gemini OAuth refresh failed: {error}") from None

    if not isinstance(payload, dict):
        raise ValueError("Gemini OAuth refresh returned a malformed response.")
    access = payload.get("access_token")
    if not isinstance(access, str) or not access:
        raise ValueError("Gemini OAuth refresh returned no access_token.")

    tok_obj["access_token"] = access
    if "expires_in" in payload:
        try:
            expires_in = int(payload["expires_in"])
            tok_obj["expires_in"] = expires_in
            new_exp_dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=expires_in)
            tok_obj["expiry"] = new_exp_dt.isoformat()
        except (ValueError, TypeError):
            pass
    if isinstance(payload.get("refresh_token"), str) and payload["refresh_token"]:
        tok_obj["refresh_token"] = payload["refresh_token"]

    if "token" in doc:
        doc["token"] = tok_obj
    else:
        doc = tok_obj
    write_token_file(tpath, doc)

    exp_iso = tok_obj.get("expiry") or ""
    until = f" (expires {exp_iso})" if exp_iso else ""
    print(f"  [✓] Refreshed the Gemini OAuth token in {tpath}{until}", file=sys.stderr)


def read_config(path: Path):
    import tomlkit
    if path.exists():
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    return tomlkit.document()


def status(home: Path, config: Path, as_json: bool) -> None:
    gdir = gemini_dir(home)
    tpath = auth_token_file(home)
    doc = read_json(tpath)
    tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc

    token = (
        os.environ.get("GEMINI_AUTH_TOKEN")
        or os.environ.get("GOOGLE_OAUTH_TOKEN")
        or str(tok_obj.get("access_token") or "")
    )
    api_key = (
        os.environ.get("GEMINI_API_KEY")
        or os.environ.get("GOOGLE_API_KEY")
        or ""
    )
    if api_key == "ollama":
        api_key = ""

    exp = parse_expiry(tok_obj.get("expiry"))
    try:
        expires = datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat() if exp else (tok_obj.get("expiry") or "Unknown")
    except (ValueError, OverflowError, OSError):
        expires = tok_obj.get("expiry") or "Unknown"

    try:
        cfg_doc = read_config(config)
    except (ImportError, OSError, ValueError):
        cfg_doc = {}

    providers = cfg_doc.get("providers", {})
    registered = cfg_doc.get("models", {})
    env = {
        key: "<set>" if os.environ.get(key) else "<unset>"
        for key in ("GEMINI_AUTH_TOKEN", "GOOGLE_OAUTH_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY")
    }

    email = doc.get("id_token_email") or tok_obj.get("email")
    auth_method = doc.get("auth_method") or ("api_key" if api_key else None)
    token_valid = (exp > time.time()) if exp is not None else (bool(token) or bool(api_key))

    data = {
        "gemini_home": str(gdir),
        "auth_file": str(tpath),
        "auth_file_exists": tpath.exists(),
        "email": email,
        "auth_method": auth_method,
        "token_present": bool(token) or bool(api_key),
        "token_valid": token_valid,
        "token_exp": exp,
        "token_exp_iso": expires,
        "env": env,
        "refreshable": bool(tok_obj.get("refresh_token")),
        "kimi": {
            "config_file": str(config),
            "provider_configured": "gemini" in providers,
            "default_model": cfg_doc.get("default_model"),
            "gemini_models": [k for k in registered if k.startswith("gemini/")],
        },
    }

    if as_json:
        print(json.dumps(data, indent=2))
        return

    print("Gemini Authentication & Kimi Code Integration")
    print(f"  Gemini Home : {gdir}")
    print(f"  Auth File   : {tpath} ({'Found' if tpath.exists() else 'Missing'})")
    if email:
        print(f"  Account     : {email}" + (f" ({auth_method})" if auth_method else ""))
    state = "Active" if token_valid else ("Expired" if exp is not None else "Unknown expiry")
    if token:
        print(f"  OAuth Token : <set> - {state} ({expires})")
    elif api_key:
        print(f"  API Key     : <set> ({api_key[:10]}...)")
    else:
        print("  Session     : <none>")
    print(f"  Refresh Token : {'Present' if data['refreshable'] else 'Absent'}")
    if state == "Expired" and data["refreshable"]:
        print("                  'kimo gemini --token' renews it automatically.")
    print("  Native authentication: run 'agy' or set GEMINI_API_KEY")
    for key, val in env.items():
        print(f"    {key} : {val}")
    print(f"  Kimi Config : {config}")
    print(f"    [providers.gemini] : {'Configured' if data['kimi']['provider_configured'] else 'Not configured'}"
          f"  ({len(data['kimi']['gemini_models'])} models)")
    print(f"    Default Model : {data['kimi']['default_model'] or '<unset>'}")
    print(f"    Gemini Models : {', '.join(data['kimi']['gemini_models']) or '<none>'}")


def default_model(home: Path, config: Path) -> str:
    try:
        doc = read_config(config)
        default = doc.get("default_model", "")
        if default.startswith("gemini/") and default in doc.get("models", {}):
            return default
    except Exception:
        pass
    return "gemini/gemini-2.5-flash"


def main():
    if len(sys.argv) < 2:
        action = "status"
    else:
        action = sys.argv[1]

    home = Path(os.environ.get("HOME") or Path.home())
    config = Path(os.environ.get("KIMI_CONFIG") or home / ".kimi-code" / "config.toml")
    as_json = "--json" in sys.argv[2:]

    if action == "status":
        status(home, config, as_json)
    elif action == "token-state":
        token_state(home)
    elif action == "token":
        tpath = auth_token_file(home)
        doc = read_json(tpath)
        tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
        exp = parse_expiry(tok_obj.get("expiry"))
        if exp is not None and exp <= time.time() + EXPIRY_SKEW_SECONDS and tok_obj.get("refresh_token"):
            if os.environ.get("KIMO_GEMINI_NO_REFRESH") != "1":
                try:
                    refresh(home)
                    doc = read_json(tpath)
                    tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
                except Exception:
                    pass
        tok = (
            os.environ.get("GEMINI_AUTH_TOKEN")
            or os.environ.get("GOOGLE_OAUTH_TOKEN")
            or str(tok_obj.get("access_token") or "")
            or os.environ.get("GEMINI_API_KEY", "")
            or os.environ.get("GOOGLE_API_KEY", "")
        )
        if tok == "ollama":
            tok = ""
        if not tok:
            print("Error: No Gemini token or API key found. Set GEMINI_API_KEY or sign in with 'agy'.", file=sys.stderr)
            sys.exit(1)
        if as_json:
            print(json.dumps({"token": tok}))
        else:
            print(tok)
    elif action == "export":
        tpath = auth_token_file(home)
        doc = read_json(tpath)
        tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
        exp = parse_expiry(tok_obj.get("expiry"))
        if exp is not None and exp <= time.time() + EXPIRY_SKEW_SECONDS and tok_obj.get("refresh_token"):
            if os.environ.get("KIMO_GEMINI_NO_REFRESH") != "1":
                try:
                    refresh(home)
                    doc = read_json(tpath)
                    tok_obj = doc.get("token") if isinstance(doc.get("token"), dict) else doc
                except Exception:
                    pass
        tok = (
            os.environ.get("GEMINI_AUTH_TOKEN")
            or os.environ.get("GOOGLE_OAUTH_TOKEN")
            or str(tok_obj.get("access_token") or "")
            or os.environ.get("GEMINI_API_KEY", "")
            or os.environ.get("GOOGLE_API_KEY", "")
        )
        if tok == "ollama":
            tok = ""
        if not tok:
            print("Error: No Gemini token or API key found. Set GEMINI_API_KEY or sign in with 'agy'.", file=sys.stderr)
            sys.exit(1)
        if tok.startswith("AIzaSy"):
            print(f"export GEMINI_API_KEY={tok}")
        else:
            print(f"export GEMINI_AUTH_TOKEN={tok}")
    elif action == "refresh":
        refresh(home)
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
