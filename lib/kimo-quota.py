#!/usr/bin/env python3
"""Account quota adapters. No inference requests; cached OAuth can refresh safely.

Account quotas, local usage estimates, and model context limits are different
measurements. Keep their source and scope explicit in the JSON and dashboard.
"""

from __future__ import annotations

import argparse
import concurrent.futures
from contextlib import contextmanager
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


# The dispatcher passes its own version (KIMO_VERSION) so client info and
# User-Agent strings never drift from the release.
VERSION = os.environ.get("KIMO_VERSION") or "unknown"
PROVIDERS = ("ollama", "gemini", "freetier", "openrouter", "web")
CLI_BINARIES = {"cursor": ("cursor-agent", "agent", "cursor")}
GUIDES = {
    "claude": "Sign in with claude auth login, then run /usage or see https://claude.ai/settings/usage",
    "codex": "Run /status in Codex; ChatGPT login is required for account rate limits.",
    "kimi": "Run /usage in Kimi Code; sign in with kimi login if the token expired.",
    "qwen": "Qwen OAuth usage is available in the account UI; API quotas belong to the configured provider.",
    "grok": "Sign in with grok login to read subscription credits, on-demand spending, and prepaid balance.",
    "agy": "Check Antigravity account quota in the CLI or Google account UI.",
    "cursor": "See https://cursor.com/dashboard?tab=usage; team admins can set CURSOR_ADMIN_API_KEY.",
    "opencode": "Run opencode stats for local token/cost estimates; account quota belongs to the configured provider.",
    "hermes": "Account quota belongs to your model provider; HERMES_USAGE_FILE can point at a --usage-file report.",
    "openclaw": "Run openclaw status --usage for provider account quotas.",
    "cyberstrike": "Account quota belongs to the configured model provider.",
    "gh": "Run gh auth login to check GitHub API rate limits (separate from Copilot quota).",
}


class QuotaError(Exception):
    def __init__(self, status: str, message: str, http_status=None):
        super().__init__(message)
        self.status = status
        self.http_status = http_status


def number(value):
    if isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def window(name, used=None, limit=None, remaining=None, used_percent=None,
           resets_at=None, unit="percent", model=None):
    used, limit, remaining = number(used), number(limit), number(remaining)
    percent = number(used_percent)
    if remaining is None and used is not None and limit is not None:
        remaining = max(0, limit - used)
    if percent is None and limit is not None and limit > 0:
        if used is not None:
            percent = used / limit * 100
        elif remaining is not None:
            percent = (1 - remaining / limit) * 100
    percent = max(0, min(100, percent)) if percent is not None else None
    return {"name": str(name), "model": model, "unit": unit,
            "used": used, "limit": limit, "remaining": remaining,
            "used_percent": percent,
            "remaining_percent": round(100 - percent, 2) if percent is not None else None,
            "resets_at": resets_at}


def read_json(path):
    try:
        with Path(path).open(encoding="utf-8") as stream:
            result = json.load(stream)
        return result if isinstance(result, dict) else {}
    except (OSError, ValueError):
        return {}


def read_dotenv(path):
    """Read plain KEY=value lines without evaluating shell code."""
    result = {}
    try:
        for line in Path(path).read_text().splitlines():
            key, sep, value = line.strip().removeprefix("export ").partition("=")
            if sep and key and not key.startswith("#"):
                result[key.strip()] = value.strip().strip("\"'")
    except OSError:
        pass
    return result


def jsonc(text):
    # Match strings before comments so URLs and escaped quotes stay intact.
    tokens = r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
    text = re.sub(tokens, lambda match: match[0] if match[0].startswith('"') else ' ', text)
    text = re.sub(r'("(?:\\.|[^"\\])*")|,\s*(?=[}\]])',
                  lambda match: match[1] or '', text)
    data = json.loads(text)
    return data if isinstance(data, dict) else {}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    # Never forward account credentials to another origin through redirects.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_json(url, timeout, headers=None, body=None, form=False):
    deadline = time.monotonic() + timeout
    payload = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode() if body is not None else None
    request = urllib.request.Request(url, data=payload, headers={
        "User-Agent": "kimo-quota", "Accept": "application/json",
        **({"Content-Type": "application/x-www-form-urlencoded" if form else "application/json"} if body is not None else {}),
        **(headers or {}),
    })
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            chunks, size = [], 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise QuotaError("timeout", "Usage response exceeded its timeout.")
                # Bound the whole response, including servers that slowly drip
                # bytes and never trigger an ordinary per-read socket timeout.
                try:
                    response.fp.raw._sock.settimeout(remaining)
                except AttributeError:
                    pass
                chunk = response.read1(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > 2 * 1024 * 1024:
                    raise QuotaError("unavailable", "Usage response exceeds the size limit.")
        data = b"".join(chunks)
        return json.loads(data)
    except urllib.error.HTTPError as error:
        status = {401: "auth_required", 403: "auth_required", 429: "rate_limited"}.get(error.code, "unavailable")
        code = error.code
        error.close()
        raise QuotaError(status, f"Usage service returned HTTP {code}.", code) from None
    except (OSError, urllib.error.URLError, TimeoutError):
        raise QuotaError("offline", "Usage service is unreachable or timed out.") from None
    except (ValueError, UnicodeError):
        raise QuotaError("unavailable", "Usage service returned invalid JSON.") from None


def command_json(args, timeout):
    try:
        completed = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise QuotaError("timeout", "CLI usage check timed out.") from None
    except OSError:
        raise QuotaError("unavailable", "CLI usage command could not start.") from None
    if completed.returncode:
        raise QuotaError("unavailable", "CLI usage check failed; check authentication in the CLI.")
    try:
        return json.loads(completed.stdout)
    except ValueError:
        raise QuotaError("unavailable", "CLI usage command did not return JSON.") from None


def native_limits(argv, timeout, label, initialize, method, notification=None, jsonrpc=False, env=None):
    """Initialize a native server and request billing without creating a session."""
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env)
    except OSError:
        raise QuotaError("unavailable", f"{label} usage server could not start.") from None
    deadline = time.monotonic() + timeout
    pending = b""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def send(message):
        if jsonrpc:
            message = {"jsonrpc": "2.0", **message}
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()

    def receive(request_id):
        nonlocal pending
        while time.monotonic() < deadline:
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict) and "method" in message and "id" in message:
                    # Never perform file operations or permission requests from
                    # a native server during an account-only check.
                    send({"id": message["id"], "error": {"code": -32601, "message": "Account check does not expose client tools."}})
                    continue
                if isinstance(message, dict) and message.get("id") == request_id:
                    if "error" in message:
                        error = message["error"]
                        text = str(error.get("message", "")) + " " + str(error.get("data", "")) if isinstance(error, dict) else ""
                        status = "auth_required" if any(word in text.lower() for word in ("auth", "login", "sign in", "401")) else "unavailable"
                        # Error data can contain provider credentials; only
                        # report a fixed message and the classified status.
                        raise QuotaError(status, f"{label} account billing request failed; check login and CLI compatibility.")
                    return message.get("result", {})
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise QuotaError("unavailable", f"{label} usage server closed before returning limits.")
            pending += chunk
            if len(pending) > 2 * 1024 * 1024:
                raise QuotaError("unavailable", f"{label} response exceeds the size limit.")
        raise QuotaError("timeout", f"{label} account check timed out.")

    try:
        send({"id": 1, "method": "initialize", "params": initialize})
        receive(1)
        if notification:
            send({"method": notification, "params": {}})
        send({"id": 2, "method": method, "params": {}})
        return receive(2)
    except (OSError, BrokenPipeError):
        raise QuotaError("unavailable", f"{label} account check could not complete.") from None
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdin.close()
        process.stdout.close()


def codex_limits(binary, timeout):
    return native_limits([binary, "app-server"], timeout, "Codex",
                         {"clientInfo": {"name": "kimo_quota", "version": VERSION}},
                         "account/rateLimits/read", notification="initialized")


def grok_limits(binary, timeout, home=None):
    env = dict(os.environ)
    if home:
        env["GROK_HOME"] = str(home)
    return native_limits([binary, "agent", "stdio"], timeout, "Grok",
                         {"protocolVersion": 1, "clientCapabilities": {},
                          "clientInfo": {"name": "kimo_quota", "version": VERSION}},
                         "_x.ai/billing", jsonrpc=True, env=env)


def grok_billing(payload):
    config = payload.get("config")
    if not isinstance(config, dict):
        return {"status": "unavailable", "windows": [], "message": "Grok returned no account billing configuration."}

    def cents(value):
        # The official proto omits zero scalar fields: an empty Cent is $0.
        amount = number(value.get("val", 0)) if isinstance(value, dict) else None
        return amount / 100 if amount is not None else None

    period = config.get("currentPeriod") or {}
    kind = str(period.get("type") or "").removeprefix("USAGE_PERIOD_TYPE_").lower()
    reset = period.get("end") or config.get("billingPeriodEnd")
    percent = number(config.get("creditUsagePercent"))
    windows = []
    if percent is not None:
        windows.append(window("Included credits" + (f" ({kind})" if kind else ""), used_percent=percent, resets_at=reset))
    elif any(config.get(key) is not None for key in ("monthlyLimit", "used")):
        windows.append(window("Included credits", used=cents(config.get("used")),
                              limit=cents(config.get("monthlyLimit")), resets_at=reset, unit="USD"))
    if any(config.get(key) is not None for key in ("onDemandCap", "onDemandUsed")):
        windows.append(window("On-demand spending", used=cents(config.get("onDemandUsed")),
                              limit=cents(config.get("onDemandCap")), unit="USD"))
    if config.get("prepaidBalance") is not None:
        windows.append(window("Prepaid balance", remaining=cents(config["prepaidBalance"]), unit="USD"))
    for entry in config.get("productUsage", []):
        if isinstance(entry, dict) and number(entry.get("usagePercent")) is not None:
            windows.append(window(str(entry.get("product", "Product credits")), used_percent=entry["usagePercent"], resets_at=reset))
    history = []
    for entry in config.get("history", []):
        if not isinstance(entry, dict):
            continue
        cycle = entry.get("billingCycle") or {}
        historical_period = entry.get("period") or {}
        history.append({"billing_cycle": {k: cycle.get(k) for k in ("year", "month")},
                        "period": {k: historical_period.get(k) for k in ("type", "start", "end")},
                        "included_used_usd": cents(entry.get("includedUsed")),
                        "on_demand_used_usd": cents(entry.get("onDemandUsed")),
                        "total_used_usd": cents(entry.get("totalUsed"))})
    return {"status": "online" if windows else "unavailable", "windows": windows,
            "plan": payload.get("subscription_tier"), "billing": {
                "period": {"type": period.get("type"), "start": period.get("start") or config.get("billingPeriodStart"), "end": reset},
                "on_demand_enabled": payload.get("on_demand_enabled"),
                "is_unified_billing_user": config.get("isUnifiedBillingUser")}, "history": history,
            "message": "Grok subscription credits, on-demand spending, and prepaid balance."}


def codex_windows(payload):
    pools = payload.get("rateLimitsByLimitId") or {"codex": payload.get("rateLimits", {})}
    result = []
    for pool, limits in pools.items():
        if not isinstance(limits, dict):
            continue
        for name in ("primary", "secondary"):
            data = limits.get(name)
            if isinstance(data, dict):
                minutes = data.get("windowDurationMins")
                label = f"{pool} {name}" + (f" ({minutes} min)" if minutes is not None else "")
                result.append(window(label, used_percent=data.get("usedPercent"), resets_at=data.get("resetsAt")))
    return result


def kimi_windows(payload):
    result = []
    labels = {"limit_5h": "5-hour quota", "limit_7d": "7-day quota",
              "limit_month_total": "Monthly total quota", "limit_month_code": "Monthly code quota"}
    for name, data in (payload.get("usages") or {}).items():
        if isinstance(data, dict) and number(data.get("used_ratio")) is not None:
            entry = window(labels.get(name, name), used_percent=number(data["used_ratio"]) * 100,
                           resets_at=data.get("reset_time"))
            entry["limit_id"] = name
            result.append(entry)
    if result:
        # The legacy limits array can repeat the same 5-hour allowance with a
        # normalized 100-unit scale. Prefer authoritative named windows.
        return result
    summary = payload.get("usage") or payload.get("summary")
    if isinstance(summary, dict):
        result.append(window("membership", used=summary.get("used"), limit=summary.get("limit"),
                             remaining=summary.get("remaining"), resets_at=summary.get("resetTime"), unit=summary.get("unit", "units")))
    for entry in payload.get("limits", []):
        detail = entry.get("detail", {})
        result.append(window(entry.get("name") or f"{entry.get('window', {}).get('duration', '?')} {entry.get('window', {}).get('timeUnit', '')}",
                             used=detail.get("used"), limit=detail.get("limit"),
                             remaining=detail.get("remaining"), resets_at=detail.get("resetTime"), unit=detail.get("unit", "units")))
    return result


def kimi_wallet(payload):
    raw = payload.get("booster_wallet") or payload.get("boosterWallet")
    if not isinstance(raw, dict) or not isinstance(raw.get("balance"), dict):
        return None, []
    balance = raw["balance"]
    if balance.get("type") != "BOOSTER":
        return None, []

    def money(data):
        if not isinstance(data, dict):
            return None, None
        amount = number(data.get("priceInCents", data.get("price_in_cents", 0)))
        return amount / 100 if amount is not None else None, data.get("currency")

    limit, currency = money(raw.get("monthlyChargeLimit", raw.get("monthly_charge_limit")))
    used, used_currency = money(raw.get("monthlyUsed", raw.get("monthly_used")))
    currency = currency or used_currency or "USD"
    total = number(balance.get("amount", 0))
    left = number(balance.get("amountLeft", balance.get("amount_left", 0)))
    # The API stores wallet amounts as fixed-point cents (1e6 per cent).
    total = total / 100_000_000 if total is not None else None
    left = left / 100_000_000 if left is not None else None
    enabled = raw.get("monthlyChargeLimitEnabled", raw.get("monthly_charge_limit_enabled", False)) is True
    data = {"balance": left, "total": total, "currency": currency,
            "monthly_limit_enabled": enabled, "monthly_limit": limit, "monthly_used": used,
            "allow_topup": raw.get("allowTopup", raw.get("allow_topup")), "status": raw.get("status")}
    windows = [window("Extra-usage balance", remaining=left, limit=total, unit=currency)]
    if enabled or used is not None:
        windows.append(window("Extra-usage monthly spending", used=used, limit=limit if enabled else None, unit=currency))
    return data, windows


def kimi_auth(home):
    """Resolve region and OAuth slot using the same endpoint scoping as Kimi."""
    directory = Path(os.environ.get("KIMI_CODE_HOME", Path(home) / ".kimi-code"))
    config_path = Path(os.environ.get("KIMI_CONFIG", directory / "config.toml"))
    provider = {}
    if config_path.is_file():
        try:
            import tomllib
            with config_path.open("rb") as stream:
                provider = tomllib.load(stream).get("providers", {}).get("managed:kimi-code", {})
        except ImportError:
            raise QuotaError("unavailable", "Python 3.11 or newer is required to read Kimi's TOML account configuration.") from None
        except (OSError, ValueError):
            raise QuotaError("unavailable", "Kimi account configuration could not be read.") from None
    ref = provider.get("oauth") or {}
    env_base = os.environ.get("KIMI_CODE_BASE_URL")
    env_host = os.environ.get("KIMI_CODE_OAUTH_HOST", os.environ.get("KIMI_OAUTH_HOST"))
    overridden = env_base is not None or env_host is not None
    global_region = False
    if not provider:
        try:
            global_region = (directory / "region").read_text().strip() == "global"
        except OSError:
            pass
    api_base = (env_base or provider.get("base_url") or
                ("https://api.kimi.ai/coding/v1" if global_region else "https://api.kimi.com/coding/v1")).rstrip("/")
    oauth_host = (env_host or (None if overridden else ref.get("oauth_host")) or
                  ("https://auth.kimi.ai" if global_region and not overridden else "https://auth.kimi.com")).rstrip("/")
    for endpoint in (api_base, oauth_host):
        url = urllib.parse.urlparse(endpoint)
        if url.scheme not in ("https", "http") or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise QuotaError("unavailable", "Kimi account endpoint configuration is invalid.")
        if url.scheme != "https" and url.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise QuotaError("unavailable", "Kimi account credentials require HTTPS outside localhost.")
    if oauth_host == "https://auth.kimi.com" and api_base == "https://api.kimi.com/coding/v1":
        storage = "kimi-code"
    else:
        encoded = json.dumps({"oauthHost": oauth_host, "baseUrl": api_base}, separators=(",", ":"), ensure_ascii=False)
        storage = "kimi-code-env-" + hashlib.sha256(encoded.encode()).hexdigest()[:16]
    if not overridden and ref.get("key"):
        configured = str(ref["key"]).removeprefix("oauth/")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", configured):
            raise QuotaError("unavailable", "Kimi OAuth credential slot is invalid.")
        # Recompute mismatched scopes like the native runtime; never reuse a
        # mainland token for a different custom/global endpoint.
        if configured == storage:
            storage = configured
    path = directory / "credentials" / (storage + ".json")
    key = os.environ.get("KIMI_CODE_API_KEY", "")
    if not key and not ref and isinstance(provider.get("api_key"), str):
        key = provider["api_key"]
    if not key and not path.is_file() and not provider and not overridden and storage == "kimi-code":
        legacy = Path(os.environ.get("KIMI_SHARE_DIR", Path(home) / ".kimi")) / "credentials/kimi-code.json"
        if legacy.is_file():
            path, directory = legacy, legacy.parent.parent
    return {"api_base": api_base, "oauth_host": oauth_host, "path": path, "home": directory,
            "storage": storage, "api_key": key,
            "region": "global" if urllib.parse.urlparse(api_base).hostname == "api.kimi.ai" else
                      "mainland-cn" if urllib.parse.urlparse(api_base).hostname == "api.kimi.com" else "custom"}


@contextmanager
def native_oauth_lock(lock, remaining, stale):
    """Interoperate with native proper-lockfile directories and heartbeats."""
    while True:
        remaining()
        try:
            lock.mkdir(mode=0o700)
            break
        except FileExistsError:
            # Respect the native client's stale threshold after interrupted
            # refreshes, while preserving locks with active heartbeats.
            try:
                if time.time() - lock.stat().st_mtime > stale:
                    lock.rmdir()
                    continue
            except FileNotFoundError:
                continue
            time.sleep(min(.05, remaining()))
    identity = lock.stat().st_ino
    stop = threading.Event()

    def heartbeat():
        while not stop.wait(1):
            try:
                if lock.stat().st_ino != identity:
                    return
                os.utime(lock, None)
            except OSError:
                return

    worker = threading.Thread(target=heartbeat, daemon=True)
    worker.start()

    def owned():
        try:
            return lock.stat().st_ino == identity
        except OSError:
            return False

    try:
        yield owned
    finally:
        stop.set()
        worker.join(timeout=1)
        try:
            if lock.stat().st_ino == identity:
                lock.rmdir()
        except OSError:
            pass


@contextmanager
def kimi_refresh_lock(auth, remaining):
    target = auth["home"] / "oauth" / auth["storage"]
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target.touch(mode=0o600, exist_ok=True)
    with native_oauth_lock(Path(str(target) + ".lock"), remaining, 5) as owned:
        yield owned


def claude_directory(home):
    # Native secure storage can use a different directory from UI settings.
    secure = os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
    configured = secure if secure is not None else os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(configured or Path(home) / ".claude")


def refresh_claude_token(directory, prior, remaining, force=False):
    """Refresh only the selected file-backed login under Claude's own locks."""
    path = directory / ".credentials.json"
    # The installed client takes the current and legacy refresh locks before
    # its secure-storage write lock. Keep that order and preserve MCP logins.
    with native_oauth_lock(directory / ".oauth_refresh.lock", remaining, 60) as owns_refresh, \
         native_oauth_lock(Path(str(directory.resolve()) + ".lock"), remaining, 60) as owns_legacy, \
         native_oauth_lock(directory / ".storage-write.lock", remaining, 15) as owns_storage:
        document = read_json(path)
        token = document.get("claudeAiOauth") or {}
        if not token.get("accessToken"):
            raise QuotaError("auth_required", "Claude login disappeared or was revoked; sign in again.")
        expiry = number(token.get("expiresAt"))
        changed = any(token.get(key) != prior.get(key) for key in ("accessToken", "refreshToken"))
        now = time.time() * 1000
        if (changed and expiry is not None and expiry > now) or (not force and expiry is not None and expiry > now + 300_000):
            return token
        refresh_expiry = number(token.get("refreshTokenExpiresAt"))
        if not token.get("refreshToken") or (refresh_expiry is not None and refresh_expiry <= now):
            raise QuotaError("auth_required", "Claude OAuth refresh token expired or is missing; sign in with claude auth login.")
        if path.is_symlink():
            raise QuotaError("unavailable", "Claude OAuth credentials cannot be refreshed through a symlink.")
        descriptor, temporary = tempfile.mkstemp(prefix=".kimo-refresh-", dir=directory)
        try:
            scopes = token.get("scopes")
            body = {"grant_type": "refresh_token", "refresh_token": token["refreshToken"],
                    "client_id": token.get("clientId") or os.environ.get("CLAUDE_CODE_OAUTH_CLIENT_ID") or
                                 "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}
            if isinstance(scopes, list) and scopes and all(isinstance(scope, str) for scope in scopes):
                body["scope"] = " ".join(scopes)
            payload = fetch_json("https://platform.claude.com/v1/oauth/token", remaining(), body=body)
            if not isinstance(payload, dict) or not isinstance(payload.get("access_token"), str) or not payload["access_token"]:
                raise QuotaError("auth_required", "Claude OAuth refresh did not return a valid access token.")
            lifetime = number(payload.get("expires_in"))
            rotated = payload.get("refresh_token", token["refreshToken"])
            if lifetime is None or lifetime <= 0 or not isinstance(rotated, str) or not rotated:
                raise QuotaError("auth_required", "Claude OAuth refresh returned incomplete credentials.")
            updated = {**token, "accessToken": payload["access_token"], "refreshToken": rotated,
                       "expiresAt": int(time.time() * 1000 + lifetime * 1000)}
            if isinstance(payload.get("scope"), str):
                updated["scopes"] = payload["scope"].split()
            refresh_lifetime = number(payload.get("refresh_token_expires_in"))
            if refresh_lifetime is not None and refresh_lifetime > 0:
                updated["refreshTokenExpiresAt"] = int(time.time() * 1000 + refresh_lifetime * 1000)
            if not all(check() for check in (owns_refresh, owns_legacy, owns_storage)) or read_json(path) != document:
                raise QuotaError("auth_required", "Claude login changed during refresh; retry the quota check.")
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                descriptor = None
                json.dump({**document, "claudeAiOauth": updated}, stream, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            return updated
        except QuotaError as error:
            if error.http_status in (400, 401, 403):
                raise QuotaError("auth_required", "Claude OAuth refresh was rejected; sign in with claude auth login.") from None
            raise
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def claude_usage(payload):
    windows = []
    labels = {"five_hour": "5-hour quota", "seven_day": "7-day quota",
              "seven_day_oauth_apps": "7-day OAuth apps quota", "seven_day_opus": "7-day Opus quota",
              "seven_day_sonnet": "7-day Sonnet quota", "session": "5-hour quota",
              "weekly": "7-day quota", "weekly_all": "7-day quota", "weekly_scoped": "7-day quota"}
    # Modern structured limits carry scoped model/surface windows that the
    # legacy top-level utilization objects cannot represent.
    for data in payload.get("limits") or []:
        if not isinstance(data, dict) or number(data.get("percent")) is None:
            continue
        kind = str(data.get("kind") or data.get("group") or "Account quota")
        if kind in ("extra_usage", "overage", "usage_credits"):
            continue
        scope = data.get("scope") or {}
        model = (scope.get("model") or {}).get("display_name")
        surface = (scope.get("surface") or {}).get("display_name")
        name = labels.get(kind, kind.replace("_", " ").title())
        if model or surface:
            name += " (" + ", ".join(str(item) for item in (model, surface) if item) + ")"
        entry = window(name, used_percent=data["percent"], resets_at=data.get("resets_at"), model=model)
        entry.update(limit_kind=kind, limit_group=data.get("group"), is_active=data.get("is_active"))
        windows.append(entry)
    if not windows:
        for name, data in payload.items():
            if name != "extra_usage" and isinstance(data, dict) and "utilization" in data:
                model = "Opus" if name == "seven_day_opus" else "Sonnet" if name == "seven_day_sonnet" else None
                entry = window(data.get("label") or labels.get(name, name.replace("_", " ").title()),
                               used_percent=data["utilization"], resets_at=data.get("resets_at"), model=model)
                entry["limit_id"] = name
                if any(data.get(key) is not None for key in ("limit_dollars", "used_dollars", "remaining_dollars")):
                    entry = {**entry, **window(entry["name"], used=data.get("used_dollars"), limit=data.get("limit_dollars"),
                                             remaining=data.get("remaining_dollars"), used_percent=data["utilization"],
                                             resets_at=data.get("resets_at"), unit="USD", model=model)}
                windows.append(entry)
    extra = payload.get("extra_usage")
    details = None
    if isinstance(extra, dict):
        currency = str(extra.get("currency") or "USD").upper()
        enabled = extra.get("is_enabled") is True
        limit, used = number(extra.get("monthly_limit")), number(extra.get("used_credits"))
        # Match Claude's native currency formatter, including its supported
        # currencies without fractional minor units.
        divisor = 1 if currency in ("JPY", "KRW", "VND") else 100
        limit = limit / divisor if limit is not None else None
        used = used / divisor if used is not None else None
        details = {"is_enabled": enabled, "monthly_limit": limit, "monthly_used": used,
                   "currency": currency, "disabled_reason": extra.get("disabled_reason")}
        if enabled or used is not None:
            windows.append(window("Extra-usage monthly spending", used=used, limit=limit if enabled else None,
                                  used_percent=extra.get("utilization") if enabled and limit is not None else None,
                                  resets_at=extra.get("resets_at"), unit=currency))
    return {"windows": windows, "extra_usage": details}


def refresh_kimi_token(auth, prior, remaining, force=False):
    with kimi_refresh_lock(auth, remaining) as owns_lock:
        token = read_json(auth["path"])
        if not token.get("access_token"):
            raise QuotaError("auth_required", "Kimi login disappeared or was revoked; sign in again.")
        changed = token.get("access_token") != prior.get("access_token") or token.get("refresh_token") != prior.get("refresh_token")
        expiry = number(token.get("expires_at"))
        if (changed and expiry is not None and expiry > time.time()) or (not force and expiry is not None and expiry > time.time() + 30):
            return token
        if not token.get("refresh_token"):
            raise QuotaError("auth_required", "Kimi OAuth token expired and has no refresh token; sign in again.")
        # Check that private atomic persistence is possible before rotating a
        # refresh token. Never log the response or write a plaintext backup.
        descriptor, temporary = tempfile.mkstemp(prefix=".kimo-refresh-", dir=auth["path"].parent)
        try:
            try:
                device = (auth["home"] / "device_id").read_text().strip()
            except OSError:
                device = str(uuid.uuid4())
            payload = fetch_json(auth["oauth_host"] + "/api/oauth/token", remaining(),
                {"X-Msh-Platform": "kimi_code_cli", "X-Msh-Device-Id": device, "User-Agent": f"kimo-quota/{VERSION}"},
                {"client_id": "17e5f671-d194-4dfb-9706-5516cb48c098", "grant_type": "refresh_token",
                 "refresh_token": token["refresh_token"]}, form=True)
            if not isinstance(payload, dict) or not isinstance(payload.get("access_token"), str) or not payload["access_token"]:
                raise QuotaError("auth_required", "Kimi token refresh did not return a valid access token.")
            lifetime = number(payload.get("expires_in"))
            if lifetime is None or lifetime <= 0 or not isinstance(payload.get("refresh_token"), str) or not payload["refresh_token"]:
                raise QuotaError("auth_required", "Kimi token refresh returned incomplete credentials.")
            updated = {**token, **{key: payload.get(key, token.get(key, "")) for key in ("access_token", "refresh_token", "scope", "token_type")},
                       "expires_in": lifetime, "expires_at": int(time.time() + lifetime)}
            if not owns_lock() or read_json(auth["path"]) != token:
                raise QuotaError("auth_required", "Kimi login changed during refresh; retry the quota check.")
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                descriptor = None
                json.dump(updated, stream, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, auth["path"])
            return updated
        except QuotaError as error:
            if error.http_status in (400, 401, 403):
                raise QuotaError("auth_required", "Kimi OAuth refresh was rejected; sign in with kimi login.") from None
            raise
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


class Dashboard:
    def __init__(self, args):
        self.args = args
        self.home = Path(args.home)
        self.model = args.model.lower()
        self.cache = {}
        self.locks = {name: threading.Lock() for name in PROVIDERS}
        self.budget = threading.local()

    def remaining_time(self):
        if not hasattr(self.budget, "deadline"):
            self.budget.deadline = time.monotonic() + self.args.timeout
        remaining = self.budget.deadline - time.monotonic()
        if remaining <= 0:
            raise QuotaError("timeout", "Quota source exceeded its timeout.")
        return remaining

    def matches(self, name):
        return not self.model or self.model in str(name).lower()

    def provider(self, name):
        if not self.locks[name].acquire(timeout=self.args.timeout):
            return {"status": "timeout", "message": "Shared provider check timed out.", "windows": []}
        try:
            if name not in self.cache:
                try:
                    self.cache[name] = getattr(self, name)()
                except QuotaError as error:
                    self.cache[name] = {"status": error.status, "message": str(error), "windows": []}
                except (OSError, TypeError, KeyError, AttributeError, ValueError):
                    self.cache[name] = {"status": "unavailable", "message": "Usage service returned an unexpected schema.", "windows": []}
            return self.cache[name]
        finally:
            self.locks[name].release()

    def online(self):
        if self.args.offline:
            raise QuotaError("offline", "Network and native CLI checks disabled by --offline.")

    def ollama(self):
        self.online()
        hosts = []
        mode = self.args.host_mode
        if mode == "multi":
            hosts = [(url, url) for url in self.args.multi_hosts.split()]
        elif mode == "custom":
            hosts = [("custom", self.args.target_host)]
        elif mode == "local":
            hosts = [("local", self.args.local_url)]
        elif mode == "remote":
            hosts = [("remote", self.args.remote_url)]
        else:
            hosts = [("local", self.args.local_url), ("remote", self.args.remote_url)]
        result = {"status": "offline", "hosts": {}, "windows": [], "quota_status": "not_metered"}
        for label, url in hosts:
            host = {"url": url, "status": "offline", "version": None, "resident": [], "installed_count": 0}
            try:
                host["version"] = fetch_json(url.rstrip("/") + "/api/version", self.remaining_time()).get("version")
                host["status"] = "online"
                result["status"] = "online"
                for endpoint in ("ps", "tags"):
                    try:
                        models = fetch_json(url.rstrip("/") + f"/api/{endpoint}", self.remaining_time()).get("models", [])
                        models = [m for m in models if self.matches(m.get("name", ""))]
                        if endpoint == "tags":
                            host["installed_count"] = len(models)
                        else:
                            host["resident"] = [{"name": m.get("name", ""),
                                "size_vram_gb": round((number(m.get("size_vram")) or 0) / 1024**3, 2),
                                "size_total_gb": round((number(m.get("size")) or 0) / 1024**3, 2),
                                "context_length": m.get("context_length"), "expires_at": m.get("expires_at")} for m in models]
                    except QuotaError:
                        pass
            except QuotaError:
                pass
            result["hosts"][label] = host
        result["message"] = "Self-hosted Ollama has no subscription quota; capacity depends on host resources."
        return result

    def gemini(self):
        key = os.environ.get("KIMO_QUOTA_GEMINI_KEY", "")
        result = {"status": "unconfigured", "key_present": bool(key), "models": [], "windows": [],
                  "rate_limits": {}, "quota_status": "unavailable",
                  "message": "Model token limits are context limits. Account rate limits are shown in Google AI Studio."}
        if not key:
            return result
        self.online()
        page = ""
        for _ in range(20):
            url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"
            if page:
                url += "&pageToken=" + urllib.parse.quote(page, safe="")
            payload = fetch_json(url, self.remaining_time(), {"x-goog-api-key": key})
            for model in payload.get("models", []):
                name = model.get("name", "").removeprefix("models/")
                if self.matches(name):
                    result["models"].append({"name": name, "display_name": model.get("displayName", ""),
                        "input_token_limit": model.get("inputTokenLimit"), "output_token_limit": model.get("outputTokenLimit"),
                        "thinking_supported": model.get("thinking", False)})
            page = payload.get("nextPageToken", "")
            if not page:
                result["status"] = "online"
                return result
        result["status"] = "partial"
        return result

    def freetier(self):
        self.online()
        binary = shutil.which("bl")
        if not binary:
            raise QuotaError("bl_cli_missing", "Install bl and log in to the Model Studio console to read free-tier quota.")
        rows = command_json([binary, "usage", "free", "--all", "--output", "json", "--console-site", "international"], self.remaining_time())
        if not isinstance(rows, list):
            raise QuotaError("auth_required", "Bailian did not return quota rows; refresh its console login.")
        rows = [{k: row.get(k) for k in ("model", "type", "unit", "remaining", "total", "used", "expires")}
                for row in rows if isinstance(row, dict) and self.matches(row.get("model", ""))]
        return {"status": "live", "models": rows, "windows": [window(row.get("model", "unknown"),
            used=row.get("used"), limit=row.get("total"), remaining=row.get("remaining"),
            resets_at=row.get("expires"), unit=row.get("unit") or "units", model=row.get("model")) for row in rows]}

    def openrouter(self, key=None):
        key = key or os.environ.get("OPENROUTER_API_KEY", "")
        if not key:
            return {"status": "unconfigured", "key_present": False, "windows": []}
        self.online()
        data = fetch_json("https://openrouter.ai/api/v1/key", self.remaining_time(),
                          {"Authorization": f"Bearer {key}"}).get("data", {})
        usage, limit = number(data.get("usage")), number(data.get("limit"))
        budget = window("API key budget", used=usage, limit=limit,
                        remaining=data.get("limit_remaining"), unit="USD")
        return {"status": "online", "key_present": True, "usage_usd": usage, "limit_usd": limit,
                "remaining_usd": budget["remaining"], "is_free_tier": data.get("is_free_tier"),
                "windows": [budget],
                "message": "No API-key spending limit set." if limit is None else "API-key spending budget."}

    def web(self):
        self.online()
        url = self.args.web_url.removesuffix("/command").rstrip("/")
        fetch_json(url + "/status", self.remaining_time())
        return {"status": "online", "url": url, "quota_status": "not_metered", "windows": []}

    def cli(self, name):
        binary = next((p for candidate in CLI_BINARIES.get(name, (name,))
                       if (p := shutil.which(candidate))), None)
        result = {"installed": bool(binary), "status": "not_installed" if not binary else "unavailable",
                  "scope": "account", "source": None, "windows": [], "message": GUIDES.get(name, "Check your model provider's usage dashboard.")}
        if not binary:
            return result
        if self.args.offline:
            result["status"] = "offline"
            return result
        try:
            data = getattr(self, "cli_" + name, self.cli_backend)(name, binary)
            result.update(data)
            result["windows"] = [w for w in result["windows"] if not w.get("model") or self.matches(w["model"])]
        except QuotaError as error:
            result.update(status=error.status, message=f"{error} {GUIDES.get(name, '')}")
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            result.update(status="unavailable", message="Usage data could not be read. " + GUIDES.get(name, ""))
        return result

    def cli_codex(self, name, binary):
        payload = codex_limits(binary, self.remaining_time())
        windows = codex_windows(payload)
        return {"status": "online" if windows else "unavailable", "source": "codex app-server account/rateLimits/read", "windows": windows}

    def cli_claude(self, name, binary):
        directory = claude_directory(self.home)
        supplied = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
        auth = {} if supplied else read_json(directory / ".credentials.json").get("claudeAiOauth", {})
        key = supplied or auth.get("accessToken")
        if not key:
            raise QuotaError("auth_required", "No Claude subscription OAuth token found.")
        scopes = auth.get("scopes")
        if isinstance(scopes, list) and "user:profile" not in scopes:
            raise QuotaError("auth_required", "Claude usage requires the user:profile OAuth scope; sign in with claude auth login.")
        allow_refresh = not getattr(self.args, "no_refresh", False)
        expiry = number(auth.get("expiresAt"))
        refreshed = False
        if expiry is not None and expiry <= time.time() * 1000 + 300_000 and auth.get("refreshToken") and allow_refresh:
            auth = refresh_claude_token(directory, auth, self.remaining_time)
            key, refreshed = auth["accessToken"], True
        elif expiry is not None and expiry <= time.time() * 1000:
            raise QuotaError("auth_required", "Claude OAuth access token expired; enable refresh or sign in again.")

        def usage():
            return fetch_json("https://api.anthropic.com/api/oauth/usage", self.remaining_time(),
                              {"Authorization": f"Bearer {key}", "anthropic-beta": "oauth-2025-04-20"})

        try:
            payload = usage()
        except QuotaError as error:
            if error.http_status != 401 or not auth.get("refreshToken") or not allow_refresh or refreshed:
                raise
            auth = refresh_claude_token(directory, auth, self.remaining_time, force=True)
            key, refreshed = auth["accessToken"], True
            payload = usage()
        data = claude_usage(payload)
        return {**data, "status": "online" if data["windows"] else "unavailable", "source": "Claude OAuth usage",
                "plan": auth.get("subscriptionType"), "rate_limit_tier": auth.get("rateLimitTier"),
                "auth": {"kind": "oauth_env" if supplied else "oauth", "refreshed": refreshed},
                "message": "Claude subscription quotas and extra-usage spending; Anthropic API-key budgets are separate."}

    def cli_kimi(self, name, binary):
        auth = kimi_auth(self.home)
        key = auth["api_key"]
        token = {} if key else read_json(auth["path"])
        refreshed = False
        allow_refresh = not getattr(self.args, "no_refresh", False)
        if not key:
            key = token.get("access_token", "")
        if not key:
            raise QuotaError("auth_required", "No Kimi Code credential found (Moonshot API keys use a separate quota).")
        expiry = number(token.get("expires_at"))
        if token and expiry is not None and expiry <= time.time() + 30 and token.get("refresh_token") and allow_refresh:
            token = refresh_kimi_token(auth, token, self.remaining_time)
            key, refreshed = token["access_token"], True
        elif token and expiry is not None and expiry <= time.time():
            raise QuotaError("auth_required", "Kimi OAuth token expired; enable refresh or sign in again.")
        try:
            payload = fetch_json(auth["api_base"] + "/usages", self.remaining_time(), {"Authorization": f"Bearer {key}"})
        except QuotaError as error:
            if error.http_status != 401 or not token.get("refresh_token") or not allow_refresh or refreshed:
                raise
            token = refresh_kimi_token(auth, token, self.remaining_time, force=True)
            refreshed = True
            payload = fetch_json(auth["api_base"] + "/usages", self.remaining_time(),
                                 {"Authorization": f"Bearer {token['access_token']}"})
        windows = kimi_windows(payload)
        extra, extra_windows = kimi_wallet(payload)
        windows.extend(extra_windows)
        return {"status": "online" if windows else "unavailable", "source": "Kimi Code /usages", "windows": windows,
                "endpoint": auth["api_base"], "auth": {"kind": "oauth" if token else "api_key", "refreshed": refreshed, "region": auth["region"]},
                "extra_usage": extra, "message": "Kimi Code account quotas and extra-usage wallet; Moonshot API budgets are separate."}

    def cli_grok(self, name, binary):
        directory = Path(os.environ.get("GROK_HOME", self.home / ".grok"))
        try:
            payload = grok_limits(binary, self.remaining_time(), directory)
            return {**grok_billing(payload), "source": "grok agent stdio _x.ai/billing", "scope": "account"}
        except QuotaError as error:
            backend = self.cli_backend(name, binary)
            if backend.get("status") in ("online", "not_metered"):
                return {**backend, "subscription_status": error.status,
                        "message": backend.get("message", "") + " Grok subscription check: " + str(error)}
            raise

    def cli_gh(self, name, binary):
        payload = command_json([binary, "api", "rate_limit"], self.remaining_time())
        windows = [window(resource, used=data.get("used"), limit=data.get("limit"),
                          remaining=data.get("remaining"), resets_at=data.get("reset"), unit="requests")
                   for resource, data in payload.get("resources", {}).items() if isinstance(data, dict)]
        return {"status": "online" if windows else "unavailable", "source": "gh api rate_limit", "windows": windows,
                "message": "GitHub API rate limits; these are separate from Copilot premium requests."}

    def cli_openclaw(self, name, binary):
        payload = command_json([binary, "status", "--usage", "--json"], self.remaining_time())
        windows = []
        for provider in payload.get("usage", {}).get("providers", []):
            if provider.get("error"):
                continue
            for data in provider.get("windows", []):
                windows.append(window(f"{provider.get('provider', '?')} {data.get('label', 'usage')}",
                    used_percent=data.get("usedPercent"), resets_at=number(data.get("resetAt")) / 1000
                    if number(data.get("resetAt")) is not None else None))
            for data in provider.get("billing", []):
                label = f"{provider.get('provider', '?')} {data.get('label') or data.get('type', 'billing')}"
                if data.get("type") == "balance":
                    windows.append(window(label, remaining=data.get("amount"), unit=data.get("unit", "credits")))
                elif data.get("type") == "budget":
                    windows.append(window(label, used=data.get("used"), limit=data.get("limit"),
                        unit=data.get("unit", "USD"), resets_at=number(data.get("resetAt")) / 1000
                        if number(data.get("resetAt")) is not None else None))
        return {"status": "online" if windows else "unavailable", "source": "openclaw status --usage --json", "windows": windows}

    def cli_cursor(self, name, binary):
        key = os.environ.get("CURSOR_ADMIN_API_KEY", "")
        if not key:
            raise QuotaError("unavailable", "Cursor CLI does not expose a headless personal-quota command.")
        import base64
        authorization = base64.b64encode((key + ":").encode()).decode()
        windows = []
        for page in range(1, 21):
            payload = fetch_json("https://api.cursor.com/teams/spend", self.remaining_time(),
                                 {"Authorization": "Basic " + authorization}, {"page": page, "pageSize": 100})
            for row in payload.get("teamMemberSpend", []):
                spend = number(row.get("spendCents"))
                windows.append(window(f"team member {len(windows) + 1}", used=spend / 100 if spend is not None else None,
                                      limit=row.get("effectivePerUserLimitDollars"), unit="USD"))
            if page >= (number(payload.get("totalPages")) or 1):
                break
        else:
            return {"status": "partial", "source": "Cursor team spend API", "scope": "team", "windows": windows,
                    "message": "Only the first 20 pages of team on-demand spending were read."}
        return {"status": "online" if windows else "unavailable", "source": "Cursor team spend API", "scope": "team", "windows": windows,
                "message": "Team on-demand spending budgets; separate from included personal-plan usage."}

    def cli_agy(self, name, binary):
        token_file = self.home / ".gemini/antigravity-cli/antigravity-oauth-token"
        token = read_json(token_file).get("token", {}).get("access_token")
        if not token:
            raise QuotaError("auth_required", "No cached Antigravity OAuth token found.")
        project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("GOOGLE_CLOUD_PROJECT_ID")
        if not project:
            account = fetch_json("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", self.remaining_time(),
                                 {"Authorization": f"Bearer {token}"}, {"metadata": {"ideType": "GEMINI_CLI"}})
            project = account.get("cloudaicompanionProject")
        if not isinstance(project, str) or not project:
            raise QuotaError("unavailable", "No Google quota project returned; set GOOGLE_CLOUD_PROJECT for this adapter.")
        payload = fetch_json("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", self.remaining_time(),
                             {"Authorization": f"Bearer {token}"}, {"project": project})
        windows = [window(bucket.get("modelId", "Google quota"), remaining=bucket.get("remainingAmount"),
                          used_percent=(1 - number(bucket["remainingFraction"])) * 100
                          if number(bucket.get("remainingFraction")) is not None else None,
                          resets_at=bucket.get("resetTime"), unit=bucket.get("tokenType", "requests"),
                          model=bucket.get("modelId")) for bucket in payload.get("buckets", [])]
        return {"status": "online" if windows else "unavailable", "source": "Google Code Assist quota", "windows": windows}

    def cli_qwen(self, name, binary):
        settings = read_json(self.home / ".qwen/settings.json")
        auth_type = settings.get("security", {}).get("auth", {}).get("selectedType")
        values = settings.get("env", {})
        url = values.get("OPENAI_BASE_URL", os.environ.get("OPENAI_BASE_URL", ""))
        if auth_type == "qwen-oauth":
            raise QuotaError("unavailable", "Qwen OAuth daily remaining quota has no supported headless readout.")
        if values.get("DASHSCOPE_API_KEY") or "dashscope" in url or os.environ.get("DASHSCOPE_API_KEY"):
            data = self.provider("freetier")
            return {**data, "scope": "provider", "source": "Bailian free-tier quota",
                    "message": "Model Studio free-tier balances; separate from Qwen OAuth daily requests and paid API budgets."}
        return self.backend_usage(name, url, values.get("OPENROUTER_API_KEY"))

    def cli_hermes(self, name, binary):
        path = os.environ.get("HERMES_USAGE_FILE")
        if path:
            data = read_json(path)
            if not data:
                raise QuotaError("unavailable", "Hermes usage report is missing or invalid.")
            return {"status": "local_usage", "scope": "session", "source": "Hermes --usage-file report", "windows": [],
                    "usage": {key: data.get(key) for key in ("model", "provider", "total_tokens", "estimated_cost_usd", "api_calls")},
                    "message": "Local session usage estimate; account remaining quota is not present in this report."}
        values = read_dotenv(Path(os.environ.get("HERMES_HOME", self.home / ".hermes")) / ".env")
        url = os.environ.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_API_BASE") or values.get("OPENAI_BASE_URL", "")
        return self.backend_usage(name, url, os.environ.get("OPENROUTER_API_KEY") or values.get("OPENROUTER_API_KEY"))

    def cli_opencode(self, name, binary):
        # Read local configuration only; do not start an OpenCode server or
        # fetch organizational config, both of which can load project plugins.
        directory = Path(os.environ.get("XDG_CONFIG_HOME", self.home / ".config")) / "opencode"
        paths = [directory / filename for filename in ("opencode.json", "opencode.jsonc")]
        if os.environ.get("OPENCODE_CONFIG"):
            paths.append(Path(os.environ["OPENCODE_CONFIG"]))
        project_paths = []
        for directory in (Path.cwd(), *Path.cwd().parents):
            project_paths.extend(directory / filename for filename in ("opencode.json", "opencode.jsonc"))
            if (directory / ".git").exists():
                break
        paths.extend(reversed(project_paths))
        config = {}

        def merge(target, source):
            for key, value in source.items():
                if isinstance(value, dict) and isinstance(target.get(key), dict):
                    merge(target[key], value)
                else:
                    target[key] = value

        for path in paths:
            if path.is_file():
                merge(config, jsonc(path.read_text()))
        if os.environ.get("OPENCODE_CONFIG_CONTENT"):
            merge(config, jsonc(os.environ["OPENCODE_CONFIG_CONTENT"]))
        provider = str(config.get("model", "")).partition("/")[0]
        options = config.get("provider", {}).get(provider, {}).get("options", {})

        def resolve(value):
            match = re.fullmatch(r"\{env:([^}]+)\}", str(value or ""))
            return os.environ.get(match[1], "") if match else value

        url = resolve(options.get("baseURL")) or ("https://openrouter.ai/api/v1" if provider == "openrouter" else "")
        key = resolve(options.get("apiKey"))
        if provider == "ollama" and not url:
            url = self.args.local_url
        return {**self.backend_usage(name, url, key),
                "configuration_scope": "local OpenCode config; remote and managed overrides are not evaluated"}

    def cli_backend(self, name, binary):
        url = os.environ.get("OPENAI_BASE_URL", os.environ.get("OPENAI_API_BASE", ""))
        if name == "grok":
            url = os.environ.get("GROK_MODELS_BASE_URL", url)
        return self.backend_usage(name, url)

    def backend_usage(self, name, url, key=None):
        url = url or ""
        hostname = urllib.parse.urlparse(url).hostname
        if hostname == "openrouter.ai":
            data = self.openrouter(key) if key and key != os.environ.get("OPENROUTER_API_KEY") else self.provider("openrouter")
            return {**data, "scope": "provider", "source": "OpenRouter API-key budget"}
        if url and url.rstrip("/").removesuffix("/v1") in (
                self.args.local_url.rstrip("/"), self.args.remote_url.rstrip("/"),
                self.args.target_host.rstrip("/"), *self.args.multi_hosts.split()):
            return {"status": "not_metered", "scope": "backend", "source": "Ollama routing", "windows": [],
                    "message": "Configured Ollama backend has no subscription quota. " + GUIDES.get(name, "")}
        return {"status": "unavailable", "windows": [], "message": GUIDES.get(name, "Check your configured model provider's account usage.")}


HIDDEN_CLI_STATUSES = ("not_installed", "unavailable", "auth_required")


def display(result, color=False, show_all=True):
    bold, cyan, reset = ("\033[1m", "\033[36m", "\033[0m") if color else ("", "", "")
    print(f"{bold}UNIFIED QUOTA & USAGE DASHBOARD{reset}")
    print("Checked:", result["timestamp"])
    clis = result["clis"] if show_all else {name: entry for name, entry in result["clis"].items()
                                            if entry["status"] not in HIDDEN_CLI_STATUSES}
    for section, entries in (("PROVIDERS", result["providers"]), ("CLI ACCOUNTS", clis)):
        if not entries:
            continue
        print(f"\n{bold}{section}{reset}")
        for name, entry in entries.items():
            print(f"\n{cyan}{name.title() if section == 'PROVIDERS' else name}{reset}: {entry['status']}")
            if entry.get("plan"):
                print("  Plan: " + str(entry["plan"]))
            period = entry.get("billing", {}).get("period", {})
            if period.get("start") or period.get("end"):
                print(f"  Billing period: {period.get('start') or 'unknown'} → {period.get('end') or 'unknown'}")
            on_demand = entry.get("billing", {}).get("on_demand_enabled")
            if isinstance(on_demand, bool):
                print("  On-demand spending: " + ("enabled" if on_demand else "disabled"))
            for label, host in entry.get("hosts", {}).items():
                print(f"  {label}: {host['status']} | {host['installed_count']} models | {host['url']}")
                for model in host["resident"]:
                    print(f"    {model['name']}: {model['size_vram_gb']:.2f} GiB VRAM")
            for data in entry.get("windows", []):
                details = []
                if data["remaining_percent"] is not None:
                    details.append(f"{data['remaining_percent']:.1f}% left")
                if data["remaining"] is not None:
                    details.append(f"{data['remaining']:g} {data['unit']} left")
                if data["used"] is not None:
                    details.append(f"{data['used']:g} {data['unit']} used")
                if data["resets_at"] is not None:
                    reset_time = data["resets_at"]
                    if isinstance(reset_time, (int, float)):
                        try:
                            reset_time = dt.datetime.fromtimestamp(reset_time, dt.timezone.utc).isoformat()
                        except (ValueError, OSError, OverflowError):
                            reset_time = "unknown"
                    details.append(f"resets {reset_time}")
                print(f"  {data['name']}: " + (" | ".join(details) or "remaining quota unknown"))
            if entry.get("message"):
                print("  " + entry["message"])
            if entry.get("usage"):
                print("  Local usage: " + json.dumps(entry["usage"]))
            if entry.get("history"):
                print(f"  {len(entry['history'])} historical billing periods available in --json.")
            if entry.get("auth", {}).get("refreshed"):
                print("  OAuth credentials refreshed securely.")
            extra = entry.get("extra_usage")
            if isinstance(extra, dict) and "monthly_limit_enabled" in extra and not extra["monthly_limit_enabled"]:
                print("  Extra-usage monthly spending cap: disabled.")
            if isinstance(extra, dict) and "is_enabled" in extra:
                print("  Extra usage: " + ("enabled" if extra["is_enabled"] else "disabled") + ".")
            if name == "gemini" and entry.get("models"):
                print(f"  {len(entry['models'])} matching models; context limits available in --json.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", default="all")
    parser.add_argument("--cli")
    parser.add_argument("--cli-names", nargs="+", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--no-refresh", action="store_true", help="Do not refresh cached Claude or Kimi OAuth credentials")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--color", action="store_true")
    parser.add_argument("--show-all", action="store_true",
                        help="List CLIs that are not installed or have no readable quota")
    parser.add_argument("--home", default=os.environ.get("KIMO_QUOTA_HOME", str(Path.home())))
    parser.add_argument("--local-url", default="http://127.0.0.1:11434")
    parser.add_argument("--remote-url", default="http://127.0.0.1:11438")
    parser.add_argument("--web-url", default="http://127.0.0.1:10086/command")
    parser.add_argument("--host-mode", default="auto")
    parser.add_argument("--target-host", default="")
    parser.add_argument("--multi-hosts", default="")
    args = parser.parse_args()
    clis = sorted(set(args.cli_names))
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
        parser.error("--timeout must be greater than 0 and at most 60 seconds")
    if args.provider not in ("all", *PROVIDERS, *clis):
        parser.error("unknown provider '" + args.provider + "'")
    if args.cli and args.cli not in ("all", *clis):
        parser.error("unknown CLI '" + args.cli + "'")
    if args.cli and args.provider != "all":
        parser.error("--cli and --provider cannot be combined")
    selected_providers = list(PROVIDERS) if args.provider == "all" and not args.cli else ([args.provider] if args.provider in PROVIDERS else [])
    selected_clis = clis if args.provider == "all" and args.cli in (None, "all") else [args.cli or args.provider] if args.cli or args.provider in clis else []
    dashboard = Dashboard(args)
    result = {"timestamp": dt.datetime.now(dt.timezone.utc).isoformat(), "providers": {}, "clis": {}}
    # Each source has a cumulative deadline. Cache locks prevent duplicate
    # requests when several CLI adapters use the same provider account.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(selected_providers) + len(selected_clis))) as executor:
        providers = {name: executor.submit(dashboard.provider, name) for name in selected_providers}
        clis = {name: executor.submit(dashboard.cli, name) for name in selected_clis}
        result["providers"] = {name: future.result() for name, future in providers.items()}
        result["clis"] = {name: future.result() for name, future in clis.items()}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        # A CLI named explicitly is always shown so its status explains itself.
        display(result, args.color, args.show_all or len(selected_clis) <= 1)


if __name__ == "__main__":
    main()
