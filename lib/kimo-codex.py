#!/usr/bin/env python3
"""Codex account inspection, ChatGPT OAuth refresh and Kimi configuration integration."""

import base64
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Codex CLI's own public OAuth client id, so a refresh here is the same renewal
# 'codex' performs itself and needs no extra registration.
CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token"
# A token this close to expiry counts as expired: launching on it would 401
# partway through a session, which is far harder to diagnose than refreshing.
EXPIRY_SKEW_SECONDS = 60

# The two OpenAI backends kimo can route a CLI at. 'codex' is the ChatGPT plan
# endpoint and takes an OAuth bearer token; 'openai' is the metered platform API
# and takes an sk- key. Both speak the Responses API, so kimi registers them the
# same way and only base_url/api_key_env differ.
PROVIDERS = {
    "codex": {
        "pid": "codex",
        "base_url": "https://chatgpt.com/backend-api/codex",
        "api_key_env": "CODEX_AUTH_TOKEN",
    },
    "openai": {
        "pid": "openai",
        "base_url": "https://api.openai.com/v1",
        "api_key_env": "OPENAI_API_KEY",
    },
}


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def claims(token):
    try:
        payload = token.split(".")[1]
        value = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        return value if isinstance(value, dict) else {}
    except (ValueError, IndexError):
        return {}


def token_expiry(token):
    value = claims(token).get("exp")
    if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return value
    return None


def catalog(home):
    models = read_json(home / "models_cache.json").get("models", [])
    if not isinstance(models, list):
        return []
    return [m for m in models if isinstance(m, dict) and isinstance(m.get("slug"), str)
            and m["slug"] and m.get("visibility", "list") == "list"]


def read_config(path):
    import tomlkit
    if path.exists():
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    return tomlkit.document()


def auth_tokens(home):
    """Return (auth document, tokens mapping) from $CODEX_HOME/auth.json."""
    auth = read_json(home / "auth.json")
    tokens = auth.get("tokens")
    return auth, (tokens if isinstance(tokens, dict) else {})


def file_access_token(tokens):
    value = tokens.get("access_token")
    return value if isinstance(value, str) else ""


def write_auth(home, auth):
    """Atomically replace auth.json, owner-only.

    Deliberately no backup file: the document holds a live refresh token, and a
    stale plaintext copy left in ~/.codex would outlive the rotation it came
    from. The write happens only after a refresh succeeded, and unknown keys are
    preserved because the parsed document is merged into, not rebuilt.
    """
    path = home / "auth.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(auth, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def token_state(home):
    """Print '<state> <source> <refreshable>' for the best available OAuth token.

    state is one of valid / expired / apikey / missing; source says whether the
    chosen token came from the environment or auth.json. Nothing here prints a
    credential, so the line is safe to capture in a shell variable.
    """
    _, tokens = auth_tokens(home)
    refreshable = "yes" if tokens.get("refresh_token") else "no"
    state = "missing"
    for source, token in (("env", os.environ.get("CODEX_AUTH_TOKEN", "")),
                          ("file", file_access_token(tokens))):
        if not token:
            continue
        if token.startswith("sk-"):
            # A platform key can never authenticate the ChatGPT endpoint, but a
            # usable OAuth token may still sit in auth.json, so keep looking.
            state = "apikey"
            continue
        expiry = token_expiry(token)
        if expiry is None or expiry > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"valid {source} {refreshable}")
            return
        state = "expired"
    print(f"{state} none {refreshable}")


def auth_mode(home):
    """Print how the Codex CLI itself will authenticate: chatgpt, apikey, none.

    Codex follows auth.json's auth_mode, not the environment, so this is what
    decides whether an exported OPENAI_API_KEY is used at all.
    """
    auth, tokens = auth_tokens(home)
    mode = auth.get("auth_mode")
    if mode == "apikey":
        print("apikey")
    elif isinstance(mode, str) and mode:
        # 'chatgpt' in current Codex builds; 'oauth' in older files.
        print("chatgpt")
    elif tokens.get("access_token") or tokens.get("refresh_token"):
        print("chatgpt")
    elif auth.get("OPENAI_API_KEY"):
        print("apikey")
    else:
        print("none")


def refresh(home):
    """Renew the ChatGPT OAuth access token from auth.json's refresh_token.

    Refresh tokens rotate: two launches renewing at once would send the same
    one, and the loser is refused (or the whole grant revoked as reuse). So
    renewals are serialized on a lock file, and a caller that waited re-reads
    auth.json and keeps a token another process already renewed.
    """
    home.mkdir(parents=True, exist_ok=True)
    timeout = float(os.environ.get("KIMO_CODEX_REFRESH_TIMEOUT") or 30)
    # kimo's private runtime dir keeps the lock out of ~/.codex; one lock per
    # Codex home. O_NOFOLLOW so a planted symlink is never opened.
    runtime = os.environ.get("KIMO_RUNTIME_DIR") or ""
    key = hashlib.sha256(str(home.resolve()).encode()).hexdigest()[:16]
    lock_path = (Path(runtime) if os.path.isdir(runtime) else home) / f".codex-auth-{key}.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        deadline = time.monotonic() + timeout + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise ValueError("Another kimo process is renewing the ChatGPT OAuth token; retry.") from None
                time.sleep(0.1)
        _, tokens = auth_tokens(home)
        current = file_access_token(tokens)
        expiry = token_expiry(current) if current and not current.startswith("sk-") else None
        if expiry is not None and expiry > time.time() + EXPIRY_SKEW_SECONDS:
            print(f"  [✓] The ChatGPT OAuth token in {home / 'auth.json'} was already renewed.", file=sys.stderr)
            return
        _refresh_locked(home, timeout)


def _refresh_locked(home, timeout):
    auth, tokens = auth_tokens(home)
    refresh_token = tokens.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        raise ValueError(f"No refresh_token in {home / 'auth.json'}; sign in again with 'kimo codex login'.")
    url = os.environ.get("KIMO_CODEX_TOKEN_URL") or CODEX_TOKEN_URL
    body = json.dumps({
        "client_id": CODEX_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email",
    }).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        # The response body is not surfaced: it echoes the grant it rejected.
        raise ValueError(
            f"ChatGPT OAuth refresh was refused (HTTP {error.code}). Sign in again with 'kimo codex login'.") from None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
        raise ValueError(f"ChatGPT OAuth refresh failed: {error}") from None
    if not isinstance(payload, dict):
        raise ValueError("ChatGPT OAuth refresh returned a malformed response.")
    access = payload.get("access_token")
    if not isinstance(access, str) or not access:
        raise ValueError("ChatGPT OAuth refresh returned no access_token.")
    tokens["access_token"] = access
    for key in ("refresh_token", "id_token"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            tokens[key] = value
    auth["tokens"] = tokens
    auth["last_refresh"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    write_auth(home, auth)
    expiry = token_expiry(access)
    until = ""
    if expiry is not None:
        try:
            until = f" (expires {datetime.datetime.fromtimestamp(expiry, datetime.timezone.utc).isoformat(timespec='seconds')})"
        except (ValueError, OverflowError, OSError):
            until = ""
    # stderr, never stdout: 'kimo codex --token' prints the credential there.
    print(f"  [✓] Refreshed the ChatGPT OAuth token in {home / 'auth.json'}{until}", file=sys.stderr)


def status(home, config, as_json):
    auth_file = home / "auth.json"
    auth = read_json(auth_file)
    tokens = auth.get("tokens")
    tokens = tokens if isinstance(tokens, dict) else {}
    token = os.environ.get("CODEX_AUTH_TOKEN", "")
    decoded = claims(token)
    profile = decoded.get("https://api.openai.com/profile")
    profile = profile if isinstance(profile, dict) else {}
    exp = token_expiry(token)
    try:
        expires = datetime.datetime.fromtimestamp(exp, datetime.timezone.utc).isoformat() if exp else "Unknown"
    except (ValueError, OverflowError, OSError):
        expires = "Unknown"
    try:
        doc = read_config(config)
    except (ImportError, OSError, ValueError):
        doc = {}
    env = {key: "<set>" if os.environ.get(key) else "<unset>" for key in
           ("CODEX_AUTH_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN")}
    providers = doc.get("providers", {})
    registered = doc.get("models", {})
    data = {
        "codex_home": str(home), "auth_file": str(auth_file), "auth_file_exists": auth_file.exists(),
        "auth_mode": auth.get("auth_mode"), "email": decoded.get("email") or profile.get("email"),
        "account_id": tokens.get("account_id"), "token_present": bool(token),
        "token_valid": exp > time.time() if exp is not None else None,
        "token_exp": exp, "token_exp_iso": expires, "env": env,
        "refreshable": bool(tokens.get("refresh_token")),
        "last_refresh": auth.get("last_refresh"),
        "kimi": {"config_file": str(config), "provider_configured": "codex" in providers,
                 "openai_configured": "openai" in providers,
                 "default_model": doc.get("default_model"),
                 "codex_models": [k for k in registered if k.startswith("codex/")],
                 "openai_models": [k for k in registered if k.startswith("openai/")]},
    }
    if as_json:
        print(json.dumps(data, indent=2))
        return
    print("Codex Authentication & Kimi Code Integration")
    print(f"  Codex Home : {home}")
    print(f"  Auth File  : {auth_file} ({'Found' if auth_file.exists() else 'Missing'})")
    if data["email"]:
        print(f"  Account Email : {data['email']}")
    if data["account_id"]:
        print(f"  Account ID : {data['account_id']}")
    state = "Active" if data["token_valid"] else "Expired" if exp is not None else "Unknown expiry"
    print(f"  Session Token : <set> - {state} ({expires})" if token else "  Session Token : <none>")
    print(f"  Refresh Token : {'Present' if data['refreshable'] else 'Absent'}"
          + (f" (last refresh {data['last_refresh']})" if data["last_refresh"] else ""))
    if state == "Expired" and data["refreshable"]:
        print("                  'kimo launch --provider codex' renews it automatically.")
    print("  Native authentication: use 'kimo codex login status' (also supports secure credential storage)")
    for key, value in env.items():
        print(f"    {key} : {value}")
    print(f"  Kimi Config : {config}")
    print(f"    [providers.codex] : {'Configured' if data['kimi']['provider_configured'] else 'Not configured'}"
          f"  ({len(data['kimi']['codex_models'])} models)")
    print(f"    [providers.openai] : {'Configured' if data['kimi']['openai_configured'] else 'Not configured'}"
          f"  ({len(data['kimi']['openai_models'])} models)")
    print(f"    Default Model : {data['kimi']['default_model'] or '<unset>'}")
    print(f"    Codex Models : {', '.join(data['kimi']['codex_models']) or '<none>'}")


def default_model(home, config, which="codex"):
    prefix = PROVIDERS[which]["pid"] + "/"
    try:
        doc = read_config(config)
        default = doc.get("default_model", "")
        if default.startswith(prefix) and default in doc.get("models", {}):
            return default
    except (ImportError, OSError, ValueError):
        pass
    models = catalog(home)
    if models:
        return prefix + models[0]["slug"]
    raise ValueError("No cached Codex models. Start Codex once to populate $CODEX_HOME/models_cache.json.")


# Reasoning efforts in ascending order, used to pick the closest thing to
# "thinking off" that a model's catalog actually offers: kimi needs a declared
# off_effort for models that reason by default, and the Codex wire rejects
# efforts the catalog does not list ("none" included, for most models).
EFFORT_RANK = ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")


def register_model(models, item, pid, alias):
    """Upsert one kimi models[alias] entry from a catalog item."""
    model = models.setdefault(alias, {})
    model["provider"] = pid
    model["model"] = item["slug"]
    model["display_name"] = item.get("display_name") or item["slug"]
    context = item.get("context_window")
    if isinstance(context, int) and not isinstance(context, bool) and context > 0:
        model["max_context_size"] = context
    caps = ["tool_use"]
    if "image" in (item.get("input_modalities") or []):
        caps.append("image_in")
    levels = item.get("supported_reasoning_levels") or []
    efforts = [level["effort"] for level in levels if isinstance(level, dict)
               and isinstance(level.get("effort"), str)]
    if efforts:
        caps.append("thinking")
        model["support_efforts"] = efforts
        default = item.get("default_reasoning_level")
        if default in efforts:
            model["default_effort"] = default
        # kimi refuses to run a model that reasons by default unless it can
        # switch thinking off (its prompt mode does); the wire only accepts
        # efforts the catalog lists, so the lowest one is the off stand-in.
        ranked = [e for e in EFFORT_RANK if e in efforts]
        model["off_effort"] = ranked[0] if ranked else efforts[0]
    model["capabilities"] = caps


def sync(home, config, selected, as_json, which="codex"):
    import tomlkit
    # The caller holds KIMI_CONFIG_LOCK. Validate the whole document before
    # creating a backup or touching the original file.
    if config.is_symlink():
        raise ValueError("Refusing to replace a symlinked Kimi config.")
    spec = PROVIDERS[which]
    pid = spec["pid"]
    prefix = pid + "/"
    doc = read_config(config)
    providers = doc.setdefault("providers", tomlkit.table())
    provider = providers.setdefault(pid, tomlkit.table())
    provider["base_url"] = spec["base_url"]
    provider["type"] = "openai_responses"
    provider["api_key_env"] = spec["api_key_env"]
    # Always use the environment reference, including when repairing a provider
    # that was configured previously with a static credential. kimo owns the
    # provider block it syncs, so keys it no longer writes (left behind by an
    # older kimo) are dropped here as well.
    provider.pop("api_key", None)
    provider.pop("custom_headers", None)
    models = doc.setdefault("models", tomlkit.table())
    available = catalog(home)
    for item in available:
        register_model(models, item, pid, prefix + item["slug"])
    if selected:
        if selected not in models:
            if available:
                raise ValueError(f"Unknown Codex model '{selected}'; choose a model from the Codex catalog.")
            # No catalog to validate against: an explicitly requested model is
            # registered on its own, so '--provider openai --model gpt-x' works
            # on a box that has never run the Codex CLI.
            if not selected.startswith(prefix):
                selected = prefix + selected.removeprefix("codex/").removeprefix("openai/")
            register_model(models, {"slug": selected.removeprefix(prefix)}, pid, selected)
        doc["default_model"] = selected
    if not any(k.startswith(prefix) for k in models):
        raise ValueError("No cached Codex models. Start Codex once to populate $CODEX_HOME/models_cache.json.")
    content = tomlkit.dumps(doc)
    tomlkit.parse(content)
    changed = not config.exists() or config.read_text(encoding="utf-8") != content
    backup = None
    if changed:
        config.parent.mkdir(parents=True, exist_ok=True)
        mode = stat.S_IMODE(config.stat().st_mode) if config.exists() else 0o600
        fd, temp = tempfile.mkstemp(prefix=".codex-config-", dir=config.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temp, mode)
            if config.exists():
                backup_fd, backup = tempfile.mkstemp(prefix=config.name + ".before-codex-", dir=config.parent)
                os.close(backup_fd)
                shutil.copyfile(config, backup)
            os.replace(temp, config)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    result = {"config_file": str(config), "changed": changed, "backup": backup, "provider": pid,
              "models": [k for k in models if k.startswith(prefix)], "default_model": doc.get("default_model")}
    if as_json:
        print(json.dumps(result))
    else:
        print(f"  [✓] {'Synchronized' if changed else 'Verified'} [providers.{pid}] and {len(result['models'])} models in {config}")
        if backup:
            print(f"  Backup: {backup}")


def check_token():
    """Fail with an actionable reason when CODEX_AUTH_TOKEN cannot work."""
    token = os.environ.get("CODEX_AUTH_TOKEN", "")
    if not token:
        raise ValueError("No ChatGPT OAuth token. Sign in with 'kimo codex login', or export CODEX_AUTH_TOKEN.")
    if token.startswith("sk-"):
        raise ValueError("An OpenAI platform API key (sk-...) cannot authenticate chatgpt.com/backend-api/codex. "
                         "Use '--provider openai' for a platform key, or 'kimo codex login' for the ChatGPT plan.")
    expiry = token_expiry(token)
    if expiry is not None and expiry <= time.time():
        raise ValueError("Codex OAuth token has expired. Refresh it with 'kimo codex login' before using Kimi.")


def main():
    action = sys.argv[1]
    home = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    config = Path(os.environ["KIMI_CONFIG"])
    as_json = "--json" in sys.argv[2:]
    positional = [a for a in sys.argv[2:] if a != "--json"]
    argument = positional[0] if positional else ""
    if action == "status":
        status(home, config, as_json)
    elif action == "default-model":
        print(default_model(home, config, argument or "codex"))
    elif action == "token-state":
        token_state(home)
    elif action == "auth-mode":
        auth_mode(home)
    elif action == "refresh":
        refresh(home)
    elif action == "check-token":
        check_token()
    elif action in ("sync", "sync-openai"):
        sync(home, config, argument, as_json, "openai" if action == "sync-openai" else "codex")
    else:
        raise ValueError(f"unknown action '{action}'")


if __name__ == "__main__":
    try:
        main()
    except ImportError:
        print("Error: python3 tomlkit is required for Codex model sync.", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
