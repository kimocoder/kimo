#!/usr/bin/env python3
"""
kimo-stream.py - Pin remote Ollama models for durable availability ('kimo stream').

The remote host typically binds ollama to its own 127.0.0.1:11434 only, so direct
LAN connections are refused by design. The reachable path is the SSH tunnel
(ollama-remote-tunnel.service): 127.0.0.1:11438 -> 127.0.0.1:11434 on the remote.
kimo passes the tunnel and direct URLs it resolved as $KIMO_REMOTE_TUNNEL_URL and
$KIMO_REMOTE_DIRECT_URL; the direct URL is empty when no remote host is known.

Historical approach (fake local manifests with 0-byte placeholder blobs) is
intentionally REMOVED: current ollama (>=0.34) verifies blob digests on load,
so those entries appear in /api/tags but fail /api/show ("EOF") and
/api/generate ("does not support generate"), and get pruned on restart.
Streaming now means: pin + warm on the remote + keepalive, with routing done
at request time (kimo run/launch auto-routes remote-only models).

Usage:
  kimo-stream.py <model> [--remote URL] [--keepalive DUR] [--no-warm] [--dry-run] [--json]
  kimo-stream.py <model> --pull
  kimo-stream.py --status [--json]
  kimo-stream.py --test [model] [--json]
  kimo-stream.py --repair-all [--remote URL] [--keepalive DUR] [--resident-only] [--dry-run] [--json]
  kimo-stream.py --all [--remote URL] [--keepalive DUR]
  kimo-stream.py --list-pinned
  kimo-stream.py --unpin <model> [--dry-run] [--json]
  kimo-stream.py --unload <model> [--dry-run] [--json]
  kimo-stream.py --tune <model> [--ctx N] [--temp T] [--predict P] [--batch B] [--gpu G]
  kimo-stream.py --show-tunings [model]
  kimo-stream.py --clear-tuning <model>
  kimo-stream.py --cleanup [model] [--dry-run] [--json]

--repair-all / --all keep the hosted catalog available at all times:
  1. discover every text model hosted on the remote (via the tunnel) and pin it,
  2. drop pins for models that no longer exist on the remote,
  3. warm (keepalive refresh) the whole pinned catalog every cycle, one model
     at a time (rotate-warm), so every hosted model is stream-ready: a
     resident big model is evicted by the next warm cycle and the stream timer
     finishes with the smallest/--stream model resident; pass --no-warm-all to
     warm only the models already resident plus pins explicitly streamed with
     'stream <model>' (warm=True) instead.
"""

import sys
import os
import json
import argparse
import subprocess
import threading
import time
import socket
import datetime
import urllib.parse
import urllib.request
import urllib.error
import contextlib
import fcntl
from concurrent.futures import ThreadPoolExecutor

try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
    _HAS_REQUESTS = True
except Exception:
    requests = None
    _HAS_REQUESTS = False

_worker_local = threading.local()
_shared_session = None
_catalog_cache = {}

REMOTE_TUNNEL_URL = (os.environ.get("KIMO_REMOTE_TUNNEL_URL") or "http://127.0.0.1:11438").rstrip("/")
REMOTE_DIRECT_URL = (os.environ.get("KIMO_REMOTE_DIRECT_URL") or "").rstrip("/")
_DIRECT = urllib.parse.urlsplit(REMOTE_DIRECT_URL) if REMOTE_DIRECT_URL else None
REMOTE_DIRECT_HOST = _DIRECT.hostname if _DIRECT else ""
REMOTE_DIRECT_PORT = (_DIRECT.port or 11434) if _DIRECT else 11434
MODELS_DIR = os.environ.get("OLLAMA_MODELS") or "/usr/share/ollama/.ollama/models"
STATE_CANDIDATES = [
    os.environ.get("OLLAMA_STREAM_STATE") or "",
    "/var/lib/ollama/streamed-models.json",
    os.path.expanduser("~/.config/ollama-streamed-models.json"),
]

# Per-model tuned defaults written by 'kimo tune' (registry). When a
# pinned model has tuned options, the warm/keepalive request includes them so
# the resident VRAM footprint matches what run/launch would use.
TUNINGS_FILE = os.environ.get("KIMO_TUNINGS_FILE") or "/var/lib/ollama/tunings.json"

# Image-pipeline models hosted on the remote (comfyui/sdxl-*) are not ollama-
# runnable text models. They stay in the remote catalog but are never pinned
# for warm residency.
NON_TEXT_MODEL_PREFIXES = ("comfyui/",)


def normalize_url(url):
    url = (url or "").strip()
    if not url.startswith("http://") and not url.startswith("https://"):
        url = f"http://{url}"
    host_part = url.split("//", 1)[1]
    if ":" not in host_part.split("/", 1)[0]:
        url = f"{url}:11434"
    return url.rstrip("/")


def _get_remote_bridge_token():
    token = os.environ.get("REMOTE_BRIDGE_TOKEN", "").strip()
    if token:
        return token
    # Auto-detect from watchdog configuration or system defaults
    for conf_path in ("/etc/ollama-watchdog.conf", "/etc/default/ollama"):
        if os.path.isfile(conf_path):
            try:
                with open(conf_path, "r", encoding="utf-8") as f:
                    for raw_line in f:
                        line = raw_line.strip()
                        if line.startswith("REMOTE_BRIDGE_TOKEN="):
                            val = line.split("=", 1)[1].strip().strip('"\'')
                            if val:
                                return val
            except Exception:
                pass
    return ""


def _remote_headers(extra=None):
    # The remote bridge requires BRIDGE_API_TOKEN on every
    # route now; without it calls get 401 and callers read that as "down".
    headers = {"User-Agent": "ollama-streamer/1.0"}
    token = _get_remote_bridge_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if extra:
        headers.update(extra)
    return headers


def get_http_session():
    """Global persistent requests.Session with connection pooling and retries."""
    global _shared_session
    if not _HAS_REQUESTS:
        return None
    if _shared_session is None:
        s = requests.Session()
        s.headers.update(_remote_headers())
        adapter = HTTPAdapter(
            pool_connections=16,
            pool_maxsize=16,
            max_retries=Retry(
                total=2,
                backoff_factor=0.3,
                status_forcelist=[502, 503, 504],
                raise_on_status=False,
            ),
        )
        s.mount("http://", adapter)
        s.mount("https://", adapter)
        _shared_session = s
    else:
        # Keep Authorization header fresh
        token = _get_remote_bridge_token()
        if token:
            _shared_session.headers["Authorization"] = f"Bearer {token}"
    return _shared_session


def url_ok(url, timeout=2):
    session = get_http_session()
    if session is not None:
        try:
            resp = session.get(f"{url}/api/version", timeout=timeout)
            return resp.status_code == 200
        except Exception:
            return False
    try:
        req = urllib.request.Request(url + "/api/version", headers=_remote_headers())
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def _tcp_port_open(host, port, timeout=0.3):
    """Fast TCP socket check before attempting HTTP requests."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except Exception:
        return False


def resolve_remote_url(explicit=None, allow_direct=False):
    """Tunnel-first remote resolution: flag > $OLLAMA_REMOTE_URL > probe."""
    if explicit:
        return normalize_url(explicit)
    env = os.environ.get("OLLAMA_REMOTE_URL") or os.environ.get("OLLAMA_HOST") or ""
    # $OLLAMA_HOST may point at a local bridge (11434/11436/11437); only trust
    # it when it looks like the tunnel/direct remote.
    if env:
        norm = normalize_url(env)
        if norm == REMOTE_TUNNEL_URL or (REMOTE_DIRECT_HOST and (norm == REMOTE_DIRECT_URL or REMOTE_DIRECT_HOST in norm)):
            return norm
    if url_ok(REMOTE_TUNNEL_URL, timeout=1.5):
        return REMOTE_TUNNEL_URL
    # The direct LAN address is loopback-only on the remote by default.
    # Fast-fail or skip direct probe unless explicitly allowed via --direct or env.
    if allow_direct and REMOTE_DIRECT_HOST:
        if _tcp_port_open(REMOTE_DIRECT_HOST, REMOTE_DIRECT_PORT, timeout=0.3):
            if url_ok(REMOTE_DIRECT_URL, timeout=1.0):
                return REMOTE_DIRECT_URL
    return REMOTE_TUNNEL_URL  # stable default even when down


def get_json(url, data=None, timeout=5):
    session = get_http_session()
    if session is not None:
        try:
            if data is not None:
                resp = session.post(url, json=data, timeout=timeout)
            else:
                resp = session.get(url, timeout=timeout)
            if not resp.ok:
                raise RuntimeError(f"HTTP {resp.status_code}: {resp.text}")
            return resp.json()
        except RuntimeError:
            raise
        except Exception as e:
            raise RuntimeError(f"Connection failed: {e}")

    req_data = None
    extra = {}
    if data is not None:
        req_data = json.dumps(data).encode("utf-8")
        extra["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=req_data, headers=_remote_headers(extra))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}")
    except Exception as e:
        raise RuntimeError(f"Connection failed: {e}")


def get_remote_tags(remote_url, force_refresh=False):
    """Fetch and cache /api/tags in-memory for the run's lifecycle."""
    norm_url = normalize_url(remote_url)
    if not force_refresh and norm_url in _catalog_cache:
        return _catalog_cache[norm_url]
    data = get_json(f"{norm_url}/api/tags", timeout=10)
    _catalog_cache[norm_url] = data
    return data


def resolve_remote_model(remote_url, model_name):
    """Find matching model tag on remote host using single-pass index lookup."""
    tags = get_remote_tags(remote_url)
    models = tags.get("models", [])
    if not models:
        return None

    target = model_name.strip()
    target_latest = f"{target}:latest"
    target_prefix = f"{target}:"
    target_lower = target.lower()
    target_base = target_lower.rsplit("/", 1)[-1].split(":", 1)[0]

    latest_match = None
    prefix_match = None
    base_match = None

    for m in models:
        name = m.get("name", "")
        # Priority 1: Exact match -> return immediately
        if name == target:
            return m
        # Priority 2: Matches with :latest
        if name == target_latest and latest_match is None:
            latest_match = m
        # Priority 3: Matches prefix (e.g. user gave 'model' and remote has 'model:quant')
        if name.startswith(target_prefix) and prefix_match is None:
            prefix_match = m
        # Priority 4: Matches base name without namespace (e.g. 'kalidroid-27B-uncensored')
        if base_match is None:
            name_base = name.lower().rsplit("/", 1)[-1].split(":", 1)[0]
            if name_base == target_base or name.lower() == target_lower:
                base_match = m

    return latest_match or prefix_match or base_match


def ensure_tunnel():
    """Best-effort: restart the SSH tunnel if it is down."""
    try:
        rc = subprocess.call(
            ["systemctl", "is-active", "--quiet", "ollama-remote-tunnel.service"]
        )
        if rc == 0:
            return True
        print("[!] SSH tunnel ollama-remote-tunnel.service not active; restarting...",
              file=sys.stderr)
        subprocess.call(["systemctl", "restart", "ollama-remote-tunnel.service"])
        time.sleep(2)
        rc = subprocess.call(
            ["systemctl", "is-active", "--quiet", "ollama-remote-tunnel.service"]
        )
        return rc == 0
    except Exception:
        return False


def warm_remote_model(remote_url, full_name, keepalive="24h", timeout=120, options=None):
    """Pre-load model into remote VRAM so it is resident and fast.

    When the model has baked per-model tune options (registry file), they are
    merged into the request so residency matches run/launch footprints.
    """
    payload = {"model": full_name, "keep_alive": keepalive, "stream": False}
    if options:
        payload["options"] = options
    try:
        data = get_json(f"{remote_url}/api/generate", payload, timeout=timeout)
    except Exception as e:
        raise RuntimeError(f"warm request failed: {e}")
    txt = json.dumps(data)
    if '"done_reason":"load"' in txt.replace(" ", "") or data.get("done") is True:
        return True, "loaded into VRAM"
    return True, f"warm response: {txt[:200]}"


def _worker_session():
    """One pooled requests.Session per worker thread (connection reuse)."""
    s = getattr(_worker_local, "sess", None)
    if s is None:
        s = get_http_session()
        if s is None and _HAS_REQUESTS:
            s = requests.Session()
            s.headers.update(_remote_headers())
        _worker_local.sess = s
    return s


def _warm_job(rurl, name, ka, tuned, timeout=120, stable="24h"):
    """Warm one model; runs inside a thread pool worker. Returns (name, rurl, ok, msg)."""
    options = tuned if isinstance(tuned, dict) and tuned else None
    payload = {"model": name, "keep_alive": ka or stable, "stream": False}
    if options:
        payload["options"] = options
    session = _worker_session()
    try:
        if session is not None:
            resp = session.post(f"{rurl}/api/generate", json=payload, timeout=(10, timeout))
            resp.raise_for_status()
            data = resp.json()
        else:
            data = get_json(f"{rurl}/api/generate", payload, timeout=timeout)
        txt = json.dumps(data)
        if '"done_reason":"load"' in txt.replace(" ", "") or data.get("done") is True:
            return name, rurl, True, "loaded into VRAM"
        return name, rurl, True, f"warm response: {txt[:200]}"
    except Exception as e:
        return name, rurl, False, str(e)


def load_tunings():
    """Per-model tuned defaults (model name -> options dict). Empty dict if none."""
    try:
        with open(TUNINGS_FILE, encoding="utf-8") as f:
            data = json.load(f) or {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_tuning(model_name, options: dict, merge=True):
    """Save or update per-model tuning options in TUNINGS_FILE with atomic locking."""
    os.makedirs(os.path.dirname(TUNINGS_FILE), exist_ok=True)
    lock_path = TUNINGS_FILE + ".lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        tunings = load_tunings()
        if merge and model_name in tunings and isinstance(tunings[model_name], dict):
            tunings[model_name].update(options)
        else:
            tunings[model_name] = options
        tmp = TUNINGS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(tunings, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, TUNINGS_FILE)
        return tunings[model_name]
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def clear_tuning(model_name):
    """Remove tuning options for model_name from TUNINGS_FILE."""
    if not os.path.exists(TUNINGS_FILE):
        return None
    lock_path = TUNINGS_FILE + ".lock"
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        tunings = load_tunings()
        matched = None
        for name in list(tunings):
            if name == model_name or name.lower() == model_name.lower():
                matched = name
                break
            if name.startswith(f"{model_name}:") or model_name in name:
                matched = name
                break
        if matched and matched in tunings:
            del tunings[matched]
            tmp = TUNINGS_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(tunings, f, indent=2, sort_keys=True)
                f.write("\n")
            os.replace(tmp, TUNINGS_FILE)
            return matched
        return None
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


@contextlib.contextmanager
def state_file_lock(mode=fcntl.LOCK_EX, timeout=10.0):
    """Advisory flock around state file operations to prevent race conditions."""
    path = state_path_for_write()
    lock_path = path + ".lock"
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    start = time.time()
    acquired = False
    try:
        while True:
            try:
                fcntl.flock(fd, mode | fcntl.LOCK_NB)
                acquired = True
                break
            except (BlockingIOError, OSError):
                if time.time() - start >= timeout:
                    raise TimeoutError(f"Could not acquire state lock {lock_path} within {timeout}s")
                time.sleep(0.05)
        yield
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except Exception:
                pass
        try:
            os.close(fd)
        except Exception:
            pass


def state_path_for_write():
    for cand in STATE_CANDIDATES:
        if not cand:
            continue
        d = os.path.dirname(cand)
        try:
            os.makedirs(d, exist_ok=True)
            # probe writability without creating 0-byte placeholders
            if os.path.exists(cand):
                if os.access(cand, os.W_OK):
                    return cand
            else:
                if os.access(d, os.W_OK):
                    return cand
        except Exception:
            continue
    return STATE_CANDIDATES[-1]


def state_path_for_read():
    for cand in STATE_CANDIDATES:
        if cand and os.path.exists(cand):
            return cand
    return None


def load_pins():
    p = state_path_for_read()
    if not p:
        return {}, None
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f), p
    except Exception:
        return {}, p


def _write_pins(pins: dict) -> str:
    path = state_path_for_write()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(pins, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
    return path


def save_pin(full_name, remote_url, keepalive, warm=True):
    with state_file_lock():
        pins, _ = load_pins()
        pins[full_name] = {
            "remote_url": remote_url,
            "keepalive": keepalive,
            "warm": bool(warm),
            "pinned_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }
        return _write_pins(pins)


def unpin_model(target_name):
    """Safely remove a model from pinned state under file lock."""
    with state_file_lock():
        pins, path = load_pins()
        matched = None
        for name in list(pins):
            if name == target_name or name.lower() == target_name.lower():
                matched = name
                break
            if name.startswith(f"{target_name}:") or target_name in name:
                matched = name
                break
        if matched and matched in pins:
            del pins[matched]
            _write_pins(pins)
            return matched, path
        return None, path


def unload_remote_model(remote_url, model_name):
    """Immediately evict a model from remote VRAM by setting keep_alive to 0."""
    payload = {"model": model_name, "keep_alive": 0, "stream": False}
    try:
        get_json(f"{remote_url}/api/generate", payload, timeout=15)
        return True, f"evicted '{model_name}' from remote VRAM (keep_alive: 0)"
    except Exception as e:
        return False, str(e)


def hosted_text_models(remote_url):
    """Text/LLM models hosted by the remote (comfyui/* image models skipped)."""
    tags = get_remote_tags(remote_url)
    models = []
    for entry in tags.get("models", []):
        name = entry.get("name", "")
        if name.split(":", 1)[0].startswith(NON_TEXT_MODEL_PREFIXES):
            continue
        models.append(entry)
    return models


def reconcile_pins(remote_url, keepalive="24h", warm_new=True, dry_run=False):
    """Synchronise pins with the remote catalog so hosted models stay available.

    New hosted models are pinned automatically; pins whose model vanished from
    the remote are dropped. Returns (pins, added, removed, state_path).
    """
    hosted = hosted_text_models(remote_url)
    hosted_names = [m["name"] for m in hosted]
    pins, state_path = load_pins()
    added, removed = [], []
    pins_copy = dict(pins)
    for name in list(pins_copy):
        if name not in hosted_names:
            del pins_copy[name]
            removed.append(name)
    for name in hosted_names:
        if name not in pins_copy:
            pins_copy[name] = {
                "remote_url": remote_url,
                "keepalive": keepalive,
                "warm": bool(warm_new),
                "pinned_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            }
            added.append(name)
    if not dry_run:
        with state_file_lock():
            state_path = _write_pins(pins_copy)
    return pins_copy, added, removed, state_path


def _check_manifest_broken(mpath, manifests_root, blobs_dir):
    try:
        with open(mpath, encoding="utf-8") as f:
            man = json.load(f)
    except Exception:
        return None
    layers = man.get("layers") or []
    for layer in layers:
        digest = layer.get("digest", "")
        hexd = digest.split(":", 1)[1] if ":" in digest else digest
        bpath = os.path.join(blobs_dir, f"sha256-{hexd}")
        if os.path.exists(bpath) and os.path.getsize(bpath) == 0:
            rel = os.path.relpath(mpath, manifests_root)
            return {"manifest": mpath, "name": rel, "blob": bpath, "digest": digest}
    return None


def find_broken_local_entries(model_filter=None):
    """Manifests whose layer blob is a 0-byte placeholder (unusable)."""
    broken = []
    manifests_root = os.path.join(MODELS_DIR, "manifests")
    blobs_dir = os.path.join(MODELS_DIR, "blobs")
    if not os.path.isdir(manifests_root):
        return broken

    filter_q = model_filter.strip().lower() if model_filter else None

    # Targeted search roots when model_filter is provided
    search_roots = [manifests_root]
    if filter_q:
        candidates = [
            os.path.join(manifests_root, filter_q),
            os.path.join(manifests_root, "registry.ollama.ai", "library", filter_q),
            os.path.join(manifests_root, "registry.ollama.ai", filter_q),
        ]
        existing = [c for c in candidates if os.path.exists(c)]
        if existing:
            search_roots = existing

    for root_target in search_roots:
        if os.path.isfile(root_target):
            entry = _check_manifest_broken(root_target, manifests_root, blobs_dir)
            if entry:
                broken.append(entry)
            continue
        for dirpath, _, filenames in os.walk(root_target):
            for fn in filenames:
                mpath = os.path.join(dirpath, fn)
                rel = os.path.relpath(mpath, manifests_root)
                # Fast pre-filter before reading & parsing JSON file
                if filter_q and filter_q not in rel.lower() and filter_q not in fn.lower():
                    continue
                entry = _check_manifest_broken(mpath, manifests_root, blobs_dir)
                if entry:
                    broken.append(entry)
    return broken


def cleanup_broken(model_filter=None, dry_run=False, as_json=False):
    broken = find_broken_local_entries(model_filter=model_filter)
    removed_items = []
    manifests_root = os.path.realpath(os.path.join(MODELS_DIR, "manifests"))
    for b in broken:
        mpath = b["manifest"]
        bpath = b["blob"]
        if dry_run:
            removed_items.append({"manifest": mpath, "blob": bpath, "model": b["name"]})
            if not as_json:
                print(f"[dry-run] Would remove broken fake manifest {mpath}")
                if os.path.exists(bpath) and os.path.getsize(bpath) == 0:
                    print(f"[dry-run] Would remove 0-byte placeholder blob {bpath}")
            continue

        try:
            os.remove(mpath)
            removed_items.append({"manifest": mpath, "blob": bpath, "model": b["name"]})
            if not as_json:
                print(f"[✓] Removed broken fake manifest {mpath}")
        except Exception as e:
            if not as_json:
                print(f"[!] Could not remove {mpath}: {e}", file=sys.stderr)
            continue
        # Remove newly-emptied parent dirs (namespace/model) so the daemon
        # (running as ollama, not root) never trips over an unowned empty dir
        # at startup. Stop at the manifests root.
        try:
            parent = os.path.dirname(mpath)
            while parent.startswith(manifests_root) and len(parent) > len(manifests_root):
                try:
                    os.rmdir(parent)
                except Exception:
                    break
                parent = os.path.dirname(parent)
        except Exception:
            pass
        try:
            if os.path.exists(bpath) and os.path.getsize(bpath) == 0:
                os.remove(bpath)
                if not as_json:
                    print(f"[✓] Removed 0-byte placeholder blob {bpath}")
        except Exception as e:
            if not as_json:
                print(f"[!] Could not remove blob {bpath}: {e}", file=sys.stderr)
    # pruning empty manifest dirs is left to ollama; never touch non-empty blobs
    if as_json:
        print(json.dumps({
            "status": "ok",
            "dry_run": dry_run,
            "filter": model_filter,
            "count": len(removed_items),
            "removed": removed_items
        }, indent=2))
    return len(removed_items)


def _is_model_resident(m):
    """Check if model entry from /api/ps is actively resident and not expired."""
    if not isinstance(m, dict) or not m.get("name"):
        return False
    exp = m.get("expires_at")
    if not exp:
        return True
    try:
        import datetime
        clean_exp = exp
        if "." in clean_exp:
            main_part, rest = clean_exp.split(".", 1)
            for sep in ("+", "-", "Z"):
                if sep in rest:
                    frac, tz = rest.split(sep, 1)
                    tz_str = "+00:00" if sep == "Z" else f"{sep}{tz}"
                    clean_exp = f"{main_part}.{frac[:6]}{tz_str}"
                    break
        dt = datetime.datetime.fromisoformat(clean_exp)
        now = datetime.datetime.now(dt.tzinfo)
        return dt > now
    except Exception:
        return True


def run_repair_all(args, mark_all_warm=False):
    """Keep the remote-hosted catalog available at all times.

    - reconcile: auto-pin every hosted text model, drop pins for vanished models,
    - rotate-warm: refresh keepalive across every pinned model each cycle so the
      whole catalog stays stream-ready (one model in VRAM at a time; the timer
      ends with the last/smallest model resident). --no-warm-all restores the
      older behaviour of only warming resident (warm=True) pins.
    """
    remote_url = resolve_remote_url(args.remote, allow_direct=getattr(args, "direct", False))
    if not url_ok(remote_url, timeout=3):
        ensure_tunnel()
    if not url_ok(remote_url, timeout=3):
        msg = f"Remote {remote_url} unreachable; tunnel down?"
        if getattr(args, "as_json", False):
            print(json.dumps({"status": "error", "error": msg}, indent=2))
        else:
            print(f"[-] {msg}", file=sys.stderr)
        return 1

    dry_run = getattr(args, "dry_run", False)
    as_json = getattr(args, "as_json", False)
    resident_only = getattr(args, "resident_only", False)
    top_priority = getattr(args, "top_priority", False)
    if resident_only or top_priority:
        warm_all = False
    else:
        warm_all = not args.__dict__.get("no_warm_all", False)

    warm_new = False if (resident_only or not warm_all) else (bool(mark_all_warm) or warm_all)
    pins, added, removed, state_path = reconcile_pins(
        remote_url, keepalive=args.keepalive, warm_new=warm_new, dry_run=dry_run)
    if not as_json:
        if added:
            pfx = "[dry-run] Would pin" if dry_run else "[+] Pinned"
            print(f"{pfx} {len(added)} hosted model(s): {', '.join(sorted(added))}")
        if removed:
            pfx = "[dry-run] Would drop pin(s) for" if dry_run else "[-] Dropped pin(s) for"
            print(f"{pfx} model(s) no longer hosted: {', '.join(sorted(removed))}")
        if not pins:
            print(f"No hosted text models to keep available (state: {state_path}).")
            return 0

    # Rotate-warm: refresh keepalive for every pinned model one at a time so the
    # whole catalog is stream-ready; --no-warm-all only warms resident pins plus
    # pins explicitly streamed with 'stream <model>' (warm=True).
    # --resident-only strictly refreshes currently loaded models (zero new loads).
    # --top-priority warms resident models, or at most 1 model if none resident.
    resident = set()
    try:
        ps_data = get_json(f"{remote_url}/api/ps", timeout=5)
        resident = {m.get("name") for m in ps_data.get("models", []) if _is_model_resident(m)}
    except Exception:
        pass

    failed = 0
    tunings = load_tunings()
    concurrency = max(1, min(int(getattr(args, "concurrency", 2) or 2), 8))
    jobs = []

    # If top_priority is set and nothing is resident, pick at most one model to load into VRAM
    priority_target = None
    if top_priority and not resident and pins:
        warm_pins = [name for name, p in sorted(pins.items()) if p.get("warm")]
        priority_target = warm_pins[0] if warm_pins else sorted(pins.keys())[0]

    for name, pin in sorted(pins.items()):
        rurl = (normalize_url(args.remote) if args.remote else pin.get("remote_url", remote_url))
        visible = name in resident
        if resident_only:
            want_warm = False  # strictly only refresh if visible/resident
        elif top_priority:
            want_warm = (name == priority_target)
        else:
            want_warm = warm_all or pin.get("warm", False) or mark_all_warm

        if not as_json:
            print(f"[ ] {name} on {rurl} -> resident={visible} warm={want_warm}", file=sys.stderr)
        if not visible and not want_warm:
            continue  # pinned & routable; do not force-load on every cycle
        ka = args.keepalive if args.keepalive != "24h" else pin.get("keepalive", "24h")
        tuned = tunings.get(name)
        if not isinstance(tuned, dict) or not tuned:
            tuned = None
        if tuned and not as_json:
            print(f"[ ] {name}: applying tuned options {json.dumps(tuned)}", file=sys.stderr)
        jobs.append((rurl, name, ka, tuned))

    warm_results = []
    if dry_run:
        for rurl, name, ka, tuned in jobs:
            visible = name in resident
            if not as_json:
                print(f"[dry-run] Would warm '{name}' on {rurl} (keepalive: {ka}, resident: {visible}, options: {json.dumps(tuned) if tuned else None})")
            warm_results.append({
                "model": name,
                "remote_url": rurl,
                "keepalive": ka,
                "resident": visible,
                "tunings": tuned,
                "simulated": True,
                "status": "simulated"
            })
    elif jobs:
        non_resident_jobs = [j for j in jobs if j[1] not in resident]
        if len(non_resident_jobs) > 1 and not resident_only and not top_priority and not as_json:
            print(f"[!] Note: Warming {len(non_resident_jobs)} non-resident models in a single cycle. "
                  f"Due to GPU VRAM limits, each large model will evict the previous one. "
                  f"Consider --resident-only or --top-priority to eliminate VRAM thrashing.",
                  file=sys.stderr)

        if concurrency > 1 and not as_json:
            print(f"[i] warming {len(jobs)} model(s) with {concurrency} worker(s)",
                  file=sys.stderr)
        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            futs = [ex.submit(_warm_job, rurl, name, ka, tuned)
                    for rurl, name, ka, tuned in jobs]
            for fut in futs:
                name, rurl, ok, msg = fut.result()
                warm_results.append({
                    "model": name,
                    "remote_url": rurl,
                    "ok": ok,
                    "message": msg,
                    "simulated": False
                })
                if ok:
                    if not as_json:
                        print(f"[✓] {name} on {rurl}: {msg}")
                else:
                    if not as_json:
                        print(f"[!] {name} failed: {msg}", file=sys.stderr)
                    failed += 1
    elif resident_only and not as_json:
        print("[i] resident-only mode: no pinned models currently resident in remote VRAM (skipped loads).",
              file=sys.stderr)

    if as_json:
        res = {
            "status": "ok" if failed == 0 else "partial_failure",
            "dry_run": dry_run,
            "remote_url": remote_url,
            "state_file": state_path,
            "reconciled": {
                "added": sorted(added),
                "removed": sorted(removed),
                "total_pinned": len(pins),
                "pins": pins
            },
            "warming": {
                "resident_only": resident_only,
                "top_priority": top_priority,
                "concurrency": concurrency,
                "warm_targets": warm_results,
                "warmed_count": len([r for r in warm_results if r.get("ok") or r.get("simulated")]),
                "failed_count": failed
            }
        }
        print(json.dumps(res, indent=2))

    return 1 if failed else 0


def get_status_data(remote_url, allow_direct=False):
    """Collect unified status: tunnel health, latency, version, VRAM resident models, and pinned catalog."""
    norm_url = resolve_remote_url(remote_url, allow_direct=allow_direct)
    t0 = time.perf_counter()
    healthy = url_ok(norm_url, timeout=3)
    latency_ms = round((time.perf_counter() - t0) * 1000, 2) if healthy else None

    version = None
    if healthy:
        try:
            ver_data = get_json(f"{norm_url}/api/version", timeout=3)
            version = ver_data.get("version")
        except Exception:
            pass

    tunnel_service = "unknown"
    try:
        rc = subprocess.call(["systemctl", "is-active", "--quiet", "ollama-remote-tunnel.service"])
        tunnel_service = "active" if rc == 0 else "inactive"
    except Exception:
        pass

    token = _get_remote_bridge_token()
    token_masked = f"{token[:6]}...{token[-4:]}" if token and len(token) > 10 else ("configured" if token else "none")

    resident_models = []
    total_vram_bytes = 0
    total_cpu_bytes = 0
    if healthy:
        try:
            ps_data = get_json(f"{norm_url}/api/ps", timeout=5)
            for m in ps_data.get("models", []):
                size = m.get("size", 0)
                size_vram = m.get("size_vram", 0)
                size_cpu = max(0, size - size_vram)
                vram_pct = round((size_vram / size * 100), 1) if size > 0 else 0.0
                total_vram_bytes += size_vram
                total_cpu_bytes += size_cpu

                exp_raw = m.get("expires_at")
                exp_seconds = None
                exp_human = "Permanent"
                is_resident = False
                if exp_raw:
                    try:
                        clean_exp = exp_raw
                        if "." in clean_exp:
                            mp, r = clean_exp.split(".", 1)
                            for sep in ("+", "-", "Z"):
                                if sep in r:
                                    frac, tz = r.split(sep, 1)
                                    tz_s = "+00:00" if sep == "Z" else f"{sep}{tz}"
                                    clean_exp = f"{mp}.{frac[:6]}{tz_s}"
                                    break
                        dt = datetime.datetime.fromisoformat(clean_exp)
                        now_dt = datetime.datetime.now(dt.tzinfo)
                        diff = (dt - now_dt).total_seconds()
                        exp_seconds = round(diff, 1)
                        if diff > 0:
                            is_resident = True
                            h = int(diff // 3600)
                            m_rem = int((diff % 3600) // 60)
                            s_rem = int(diff % 60)
                            if h > 0:
                                exp_human = f"{h}h {m_rem:02d}m {s_rem:02d}s"
                            elif m_rem > 0:
                                exp_human = f"{m_rem}m {s_rem:02d}s"
                            else:
                                exp_human = f"{s_rem}s"
                        else:
                            is_resident = False
                            exp_human = "Expired (pending GC)"
                    except Exception:
                        exp_human = str(exp_raw)
                        is_resident = True
                else:
                    is_resident = True

                resident_models.append({
                    "name": m.get("name", ""),
                    "model": m.get("model", ""),
                    "size_bytes": size,
                    "size_vram_bytes": size_vram,
                    "size_cpu_bytes": size_cpu,
                    "vram_percent": vram_pct,
                    "context_length": m.get("context_length"),
                    "expires_at": exp_raw,
                    "expires_in_seconds": exp_seconds,
                    "expires_in_human": exp_human,
                    "is_resident": is_resident,
                    "details": m.get("details") or {},
                })
        except Exception:
            pass

    pins, state_path = load_pins()
    tunings = load_tunings()
    resident_names = {rm["name"] for rm in resident_models if rm.get("is_resident")}

    pinned_list = []
    for pname, pdata in sorted(pins.items()):
        is_res = pname in resident_names
        ptuning = tunings.get(pname)
        pinned_list.append({
            "name": pname,
            "remote_url": pdata.get("remote_url", norm_url),
            "keepalive": pdata.get("keepalive", "24h"),
            "warm": pdata.get("warm", False),
            "pinned_at": pdata.get("pinned_at", ""),
            "is_resident": is_res,
            "tunings": ptuning if isinstance(ptuning, dict) else None,
        })

    return {
        "status": "ok" if healthy else "unreachable",
        "tunnel": {
            "remote_url": norm_url,
            "healthy": healthy,
            "latency_ms": latency_ms,
            "ollama_version": version,
            "service_active": tunnel_service == "active",
            "tunnel_service": tunnel_service,
            "bridge_token_configured": bool(token),
            "bridge_token_masked": token_masked,
        },
        "vram_resident_models": resident_models,
        "pinned_models": pinned_list,
        "summary": {
            "total_pinned": len(pinned_list),
            "total_resident": len(resident_names),
            "total_vram_gb": round(total_vram_bytes / (1024 ** 3), 2),
            "total_cpu_offload_gb": round(total_cpu_bytes / (1024 ** 3), 2),
        },
        "state_file": state_path,
        "tunings_file": TUNINGS_FILE,
    }


def render_status_dashboard(status_data, as_json=False):
    """Format and print unified status dashboard."""
    if as_json:
        print(json.dumps(status_data, indent=2))
        return

    tunnel = status_data.get("tunnel", {})
    rurl = tunnel.get("remote_url", "unknown")
    healthy = tunnel.get("healthy", False)
    lat = tunnel.get("latency_ms")
    lat_str = f"{lat:.1f} ms" if lat is not None else "timeout"
    health_str = f"Healthy ({lat_str} latency)" if healthy else "UNREACHABLE"
    ver_str = tunnel.get("ollama_version") or "unknown"
    svc_str = tunnel.get("tunnel_service", "unknown")
    token_str = f"Active ({tunnel.get('bridge_token_masked')})" if tunnel.get("bridge_token_configured") else "None"

    print("=" * 80)
    print("                     OLLAMA STREAMED MODEL STATUS")
    print("=" * 80)
    print(f"  Remote Endpoint:   {rurl} ({health_str})")
    print(f"  Remote Version:    {ver_str}")
    print(f"  Tunnel Service:    ollama-remote-tunnel.service ({svc_str})")
    print(f"  Bridge Token:      {token_str}")
    print(f"  State File:        {status_data.get('state_file')}")
    print(f"  Tunings File:      {status_data.get('tunings_file')}")
    print("=" * 80)

    # VRAM Residency table
    res_models = status_data.get("vram_resident_models", [])
    print("ACTIVE VRAM / GPU RESIDENCY (/api/ps)")
    print("-" * 80)
    if not res_models:
        print("  (No models currently resident in remote VRAM)")
    else:
        print(f"  {'MODEL':<34} {'TOTAL':<10} {'VRAM':<10} {'CPU OFF':<10} {'GPU %':<7} {'EXPIRES IN'}")
        print(f"  {'-'*32}  {'-'*8}  {'-'*8}  {'-'*8}  {'-'*5}  {'-'*14}")
        for m in res_models:
            mname = m.get("name", "")
            if len(mname) > 33:
                mname = mname[:30] + "..."
            tot = f"{m.get('size_bytes', 0) / (1024**3):.1f} GB"
            vram = f"{m.get('size_vram_bytes', 0) / (1024**3):.1f} GB"
            cpu = f"{m.get('size_cpu_bytes', 0) / (1024**3):.1f} GB"
            pct = f"{m.get('vram_percent', 0):.0f}%"
            exp = m.get("expires_in_human", "")
            print(f"  {mname:<34} {tot:<10} {vram:<10} {cpu:<10} {pct:<7} {exp}")

    # Pinned catalog table
    pins = status_data.get("pinned_models", [])
    summary = status_data.get("summary", {})
    print("-" * 80)
    print(f"PINNED CATALOG MODELS ({summary.get('total_pinned', 0)} pinned | {summary.get('total_resident', 0)} resident in VRAM)")
    print("-" * 80)
    if not pins:
        print("  (No pinned models found in state file)")
    else:
        print(f"  {'MODEL':<36} {'RESIDENT':<10} {'KEEPALIVE':<11} {'TUNED OPTIONS'}")
        print(f"  {'-'*34}  {'-'*8}  {'-'*9}  {'-'*20}")
        for p in pins:
            pname = p.get("name", "")
            if len(pname) > 35:
                pname = pname[:32] + "..."
            res_str = "YES" if p.get("is_resident") else "NO"
            ka_str = p.get("keepalive", "24h")
            topts = p.get("tunings")
            topts_str = ", ".join(f"{k}: {v}" for k, v in topts.items()) if isinstance(topts, dict) and topts else "-"
            print(f"  {pname:<36} {res_str:<10} {ka_str:<11} {topts_str}")

    print("=" * 80)
    print(f"Summary: VRAM in use: {summary.get('total_vram_gb', 0)} GB | CPU offload: {summary.get('total_cpu_offload_gb', 0)} GB | Resident: {summary.get('total_resident', 0)}/{summary.get('total_pinned', 0)} models")
    print("=" * 80)


def run_smoke_test(remote_url, target_name=None, as_json=False):
    """Run lightweight 1-token generation probe to verify end-to-end inference."""
    norm_url = resolve_remote_url(remote_url)
    if not url_ok(norm_url, timeout=3):
        ensure_tunnel()
    if not url_ok(norm_url, timeout=3):
        msg = f"Remote {norm_url} unreachable for smoke test"
        if as_json:
            print(json.dumps({"status": "error", "passed": False, "error": msg}, indent=2))
        else:
            print(f"[-] {msg}", file=sys.stderr)
        return 1

    # Resolve target model
    full_name = None
    if target_name:
        try:
            m = resolve_remote_model(norm_url, target_name)
            if m:
                full_name = m.get("name")
        except Exception as e:
            msg = f"Error resolving model '{target_name}': {e}"
            if as_json:
                print(json.dumps({"status": "error", "passed": False, "error": msg}, indent=2))
            else:
                print(f"[-] {msg}", file=sys.stderr)
            return 1
        if not full_name:
            msg = f"Model '{target_name}' not found on remote server {norm_url}"
            if as_json:
                print(json.dumps({"status": "error", "passed": False, "error": msg}, indent=2))
            else:
                print(f"[-] {msg}", file=sys.stderr)
            return 1
    else:
        # Auto-pick: first resident model, or first pinned model, or first catalog model
        try:
            ps_data = get_json(f"{norm_url}/api/ps", timeout=5)
            resident = [m["name"] for m in ps_data.get("models", []) if _is_model_resident(m)]
            if resident:
                full_name = resident[0]
        except Exception:
            pass
        if not full_name:
            pins, _ = load_pins()
            if pins:
                full_name = sorted(pins.keys())[0]
        if not full_name:
            tags = get_remote_tags(norm_url)
            models = tags.get("models", [])
            if models:
                full_name = models[0]["name"]

    if not full_name:
        msg = "No remote models found to test"
        if as_json:
            print(json.dumps({"status": "error", "passed": False, "error": msg}, indent=2))
        else:
            print(f"[-] {msg}", file=sys.stderr)
        return 1

    # Probe payload
    payload = {
        "model": full_name,
        "prompt": "Say hi in one word",
        "stream": False,
        "options": {
            "num_predict": 1,
            "temperature": 0.0
        }
    }
    tuned = load_tunings().get(full_name)
    if isinstance(tuned, dict):
        for k, v in tuned.items():
            if k != "num_predict":
                payload["options"][k] = v

    if not as_json:
        print(f"[*] Sending 1-token smoke probe to '{full_name}' on {norm_url}...")

    t0 = time.perf_counter()
    try:
        resp = get_json(f"{norm_url}/api/generate", payload, timeout=120)
        wall_time_ms = round((time.perf_counter() - t0) * 1000, 2)
    except Exception as e:
        wall_time_ms = round((time.perf_counter() - t0) * 1000, 2)
        if as_json:
            print(json.dumps({
                "status": "error",
                "passed": False,
                "model": full_name,
                "remote_url": norm_url,
                "wall_time_ms": wall_time_ms,
                "error": str(e)
            }, indent=2))
        else:
            print(f"[-] Smoke test FAILED for '{full_name}': {e}", file=sys.stderr)
        return 1

    resp_text = resp.get("response", "").strip()
    eval_count = resp.get("eval_count", 0)
    eval_ns = resp.get("eval_duration", 0)
    prompt_count = resp.get("prompt_eval_count", 0)
    prompt_ns = resp.get("prompt_eval_duration", 0)
    load_ns = resp.get("load_duration", 0)
    done = resp.get("done", False)

    tok_per_sec = round(eval_count / (eval_ns / 1e9), 2) if eval_ns > 0 and eval_count > 0 else 0.0
    prompt_tok_per_sec = round(prompt_count / (prompt_ns / 1e9), 2) if prompt_ns > 0 and prompt_count > 0 else 0.0
    load_ms = round(load_ns / 1e6, 2)
    prompt_eval_ms = round(prompt_ns / 1e6, 2)

    passed = bool(done)
    res_data = {
        "status": "ok" if passed else "incomplete",
        "passed": passed,
        "model": full_name,
        "remote_url": norm_url,
        "wall_time_ms": wall_time_ms,
        "response": resp_text,
        "eval_count": eval_count,
        "tokens_per_second": tok_per_sec,
        "prompt_tokens_per_second": prompt_tok_per_sec,
        "prompt_eval_duration_ms": prompt_eval_ms,
        "load_duration_ms": load_ms,
        "done_reason": resp.get("done_reason", "stop")
    }

    if as_json:
        print(json.dumps(res_data, indent=2))
    else:
        status_word = "PASSED" if passed else "INCOMPLETE"
        print(f"[✓] Smoke test {status_word} for '{full_name}' on {norm_url}:")
        print(f"    Generated token:  \"{resp_text}\"")
        print(f"    Eval speed:       {eval_count} token(s) @ {tok_per_sec} tokens/sec")
        print(f"    Prompt eval:      {prompt_count} token(s) ({prompt_eval_ms} ms)")
        print(f"    Load duration:    {load_ms} ms")
        print(f"    Total latency:    {wall_time_ms} ms")
        print("    Health:           Ready for agent and interactive generation")

    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(
        description="Pin remote Ollama models for durable availability.")
    parser.add_argument("model", nargs="?",
                        help="Name of model to pin/stream from remote host")
    parser.add_argument("--remote", default=None,
                        help="Remote Ollama host (default: tunnel-first auto-detect)")
    parser.add_argument("--pull", action="store_true",
                        help="Download full model weights locally via ollama pull")
    parser.add_argument("--keepalive", default="24h",
                        help="Remote VRAM residency for warm (default: 24h)")
    parser.add_argument("--no-warm", "--pin-only", dest="no_warm", action="store_true",
                        help="Pin without pre-warming remote VRAM")
    parser.add_argument("--repair-all", action="store_true",
                        help="Re-warm pinned models and reconcile the hosted catalog (keepalive timer)")
    parser.add_argument("--all", "--pin-all", dest="pin_all", action="store_true",
                        help="Pin every hosted text model and keep the catalog available (alias of --repair-all)")
    parser.add_argument("--warm-all", action="store_true",
                        help="With --repair-all/--all: force-warm every pinned model (default behaviour now; kept for compatibility)")
    parser.add_argument("--no-warm-all", action="store_true",
                        help="With --repair-all/--all: only warm resident models and pins streamed with 'stream <model>'")
    parser.add_argument("--resident-only", action="store_true",
                        help="With --repair-all/--all: only refresh keepalive for models currently resident in remote VRAM (no new model loads, zero VRAM thrashing)")
    parser.add_argument("--top-priority", action="store_true",
                        help="With --repair-all/--all: warm only resident models, or at most one model if none resident")
    parser.add_argument("--unpin", action="store_true",
                        help="Remove a pinned model from state")
    parser.add_argument("--unload", "--evict", dest="unload", action="store_true",
                        help="Immediately evict model from remote VRAM (keep_alive: 0)")
    parser.add_argument("--status", "--ps", "--info", dest="status", action="store_true",
                        help="Unified status dashboard: SSH tunnel health, latency, VRAM footprint, countdowns, and pinned models")
    parser.add_argument("--test", "--check", dest="test", action="store_true",
                        help="Run end-to-end smoke test / 1-token generation probe (optionally specify model)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Simulate actions without writing state or sending heavy warm requests")
    parser.add_argument("--json", dest="as_json", action="store_true",
                        help="Format output as JSON for programmatic consumption")
    parser.add_argument("--direct", action="store_true",
                        help="Attempt direct LAN connection to the remote host ($KIMO_REMOTE_DIRECT_URL) rather than tunnel-first")
    parser.add_argument("--tune", action="store_true",
                        help="Save/update per-model tuning options in tunings.json")
    parser.add_argument("--show-tunings", "--show-tuning", dest="show_tunings", action="store_true",
                        help="Display registered tuning options (all models or specified model)")
    parser.add_argument("--clear-tuning", action="store_true",
                        help="Remove tuning options for the specified model in tunings.json")
    parser.add_argument("--ctx", "--num-ctx", dest="opt_ctx", type=int, default=None,
                        help="Tuned context window size (num_ctx)")
    parser.add_argument("--temp", "--temperature", dest="opt_temp", type=float, default=None,
                        help="Tuned sampling temperature (temperature)")
    parser.add_argument("--predict", "--num-predict", dest="opt_predict", type=int, default=None,
                        help="Tuned max tokens to predict (num_predict)")
    parser.add_argument("--batch", "--num-batch", dest="opt_batch", type=int, default=None,
                        help="Tuned batch size (num_batch)")
    parser.add_argument("--gpu", "--num-gpu", dest="opt_num_gpu", type=int, default=None,
                        help="Tuned GPU offload layers (num_gpu)")
    parser.add_argument("--concurrency", type=int, default=2,
                        help="Parallel warm workers for --repair-all/--all (1-8, default 2)")
    parser.add_argument("--list-pinned", action="store_true",
                        help="Show pinned models")
    parser.add_argument("--cleanup", action="store_true",
                        help="Remove broken fake local manifests (0-byte blobs)")
    args = parser.parse_args()

    # Collect tuning parameters if provided
    cli_tuning = {}
    if args.opt_ctx is not None:
        cli_tuning["num_ctx"] = args.opt_ctx
    if args.opt_temp is not None:
        cli_tuning["temperature"] = args.opt_temp
    if args.opt_predict is not None:
        cli_tuning["num_predict"] = args.opt_predict
    if args.opt_batch is not None:
        cli_tuning["num_batch"] = args.opt_batch
    if args.opt_num_gpu is not None:
        cli_tuning["num_gpu"] = args.opt_num_gpu

    if args.status:
        remote_url = resolve_remote_url(args.remote, allow_direct=getattr(args, "direct", False))
        if not url_ok(remote_url, timeout=3):
            ensure_tunnel()
        status_data = get_status_data(remote_url, allow_direct=getattr(args, "direct", False))
        render_status_dashboard(status_data, as_json=args.as_json)
        return 0 if status_data.get("tunnel", {}).get("healthy") else 1

    if args.test:
        remote_url = resolve_remote_url(args.remote, allow_direct=getattr(args, "direct", False))
        target_name = (args.model or "").strip()
        return run_smoke_test(remote_url, target_name=target_name, as_json=args.as_json)

    if args.show_tunings:
        tunings = load_tunings()
        target = (args.model or "").strip()
        if target:
            matched_opts = None
            matched_name = None
            for name, opts in tunings.items():
                if name == target or name.lower() == target.lower() or target in name:
                    matched_opts = opts
                    matched_name = name
                    break
            if matched_opts is not None:
                print(json.dumps({"model": matched_name, "tunings": matched_opts}, indent=2))
                return 0
            else:
                print(f"[-] No tuned options found for '{target}' in {TUNINGS_FILE}", file=sys.stderr)
                return 1
        print(json.dumps({"tunings_file": TUNINGS_FILE, "tunings": tunings}, indent=2))
        return 0

    if args.clear_tuning:
        target_name = (args.model or "").strip()
        if not target_name:
            print("error: a MODEL is required for --clear-tuning", file=sys.stderr)
            return 2
        removed = clear_tuning(target_name)
        if args.as_json:
            print(json.dumps({"status": "ok" if removed else "not_found", "model": target_name, "removed": removed, "tunings_file": TUNINGS_FILE}, indent=2))
            return 0 if removed else 1
        if removed:
            print(f"[✓] Cleared tuning options for '{removed}' in {TUNINGS_FILE}")
            return 0
        else:
            print(f"[-] No tuning options found for '{target_name}' in {TUNINGS_FILE}", file=sys.stderr)
            return 1

    if args.tune and not cli_tuning and not args.model:
        print("error: --tune requires a MODEL and at least one option (--ctx, --temp, --predict, --batch, --gpu)",
              file=sys.stderr)
        return 2

    if args.tune and (args.model or "").strip():
        target_name = args.model.strip()
        if not cli_tuning:
            print(f"error: --tune requires at least one option (--ctx, --temp, --predict, --batch, --gpu) for '{target_name}'",
                  file=sys.stderr)
            return 2
        pins, _ = load_pins()
        resolved_name = target_name
        for p in pins:
            if p == target_name or target_name in p:
                resolved_name = p
                break
        saved = save_tuning(resolved_name, cli_tuning, merge=True)
        print(f"[✓] Saved tuning for '{resolved_name}' in {TUNINGS_FILE}:")
        print(json.dumps(saved, indent=2))
        if args.no_warm:
            return 0

    if args.list_pinned:
        pins, path = load_pins()
        print(json.dumps({"state_file": path, "pins": pins}, indent=2))
        return 0

    if args.unpin:
        target_name = (args.model or "").strip()
        if not target_name:
            print("error: a MODEL is required for --unpin", file=sys.stderr)
            return 2
        if args.dry_run:
            pins, path = load_pins()
            found = target_name in pins
            if args.as_json:
                print(json.dumps({"status": "ok", "dry_run": True, "action": "unpin", "model": target_name, "found": found, "state_file": path}, indent=2))
            else:
                if found:
                    print(f"[dry-run] Would unpin '{target_name}' from {path}")
                else:
                    print(f"[dry-run] Model '{target_name}' not found in {path}")
            return 0 if found else 1
        removed, path = unpin_model(target_name)
        if args.as_json:
            print(json.dumps({"status": "ok" if removed else "not_found", "dry_run": False, "action": "unpin", "model": target_name, "removed": removed, "state_file": path}, indent=2))
            return 0 if removed else 1
        if removed:
            print(f"[✓] Unpinned '{removed}' from {path}")
            return 0
        else:
            print(f"[-] Model '{target_name}' was not found in {path}", file=sys.stderr)
            return 1

    if args.unload:
        target_name = (args.model or "").strip()
        if not target_name:
            print("error: a MODEL is required for --unload", file=sys.stderr)
            return 2
        remote_url = resolve_remote_url(args.remote, allow_direct=getattr(args, "direct", False))
        if args.dry_run:
            if args.as_json:
                print(json.dumps({"status": "ok", "dry_run": True, "action": "unload", "model": target_name, "remote_url": remote_url}, indent=2))
            else:
                print(f"[dry-run] Would unload '{target_name}' from {remote_url} (keep_alive: 0)")
            return 0
        ok, msg = unload_remote_model(remote_url, target_name)
        if args.as_json:
            print(json.dumps({"status": "ok" if ok else "error", "dry_run": False, "action": "unload", "model": target_name, "message": msg}, indent=2))
            return 0 if ok else 1
        if ok:
            print(f"[✓] {msg}")
            return 0
        else:
            print(f"[!] Unload failed: {msg}", file=sys.stderr)
            return 1

    if args.cleanup and not args.model and not args.repair_all and not args.pin_all:
        removed = cleanup_broken(dry_run=args.dry_run, as_json=args.as_json)
        if not args.as_json:
            pfx = "Would remove" if args.dry_run else "Removed"
            print(f"{pfx} {removed} broken fake manifest(s).")
        return 0

    if args.repair_all or args.pin_all:
        return run_repair_all(args)

    target_name = (args.model or "").strip()
    if not target_name:
        parser.print_usage(sys.stderr)
        print("error: a MODEL is required (or use --status/--test/--repair-all/--all/--list-pinned/--cleanup)",
              file=sys.stderr)
        return 2

    if args.cleanup:
        removed = cleanup_broken(target_name, dry_run=args.dry_run, as_json=args.as_json)
        if not args.as_json:
            pfx = "Would remove" if args.dry_run else "Removed"
            print(f"{pfx} {removed} broken fake manifest(s) for '{target_name}'.")
        # continue to (re-)pin below unless caller only wanted cleanup
        if args.no_warm and args.keepalive == "24h":
            return 0

    if args.pull:
        print(f"[*] Pulling full model '{target_name}' from registry to local storage...")
        rc = subprocess.call(["ollama", "pull", target_name])
        sys.exit(rc)

    remote_url = resolve_remote_url(args.remote, allow_direct=getattr(args, "direct", False))
    if not url_ok(remote_url, timeout=3):
        ensure_tunnel()
    if not url_ok(remote_url, timeout=3):
        print(f"[-] Remote {remote_url} unreachable. Is "
              f"ollama-remote-tunnel.service running? (systemctl status "
              f"ollama-remote-tunnel.service)", file=sys.stderr)
        if REMOTE_DIRECT_URL:
            print(f"    Direct {REMOTE_DIRECT_URL} is expected to refuse connections "
                  f"(remote binds loopback only); use the {REMOTE_TUNNEL_URL} tunnel.",
                  file=sys.stderr)
        sys.exit(1)

    if not args.as_json:
        print(f"[*] Querying remote server ({remote_url}) for model '{target_name}'...")
    try:
        model_info = resolve_remote_model(remote_url, target_name)
    except Exception as e:
        print(f"[-] Error querying remote server: {e}", file=sys.stderr)
        sys.exit(1)

    if not model_info:
        print(f"[-] Model '{target_name}' not found on remote server {remote_url}.",
              file=sys.stderr)
        sys.exit(1)

    full_name = model_info["name"]
    size_gb = model_info.get("size", 0) / (1024 ** 3)
    details = model_info.get("details") or {}
    param_size = details.get("parameter_size", "unknown")
    quant = details.get("quantization_level", "unknown")
    if not args.as_json:
        print(f"[+] Found remote model: {full_name} ({param_size}, {quant}, {size_gb:.1f} GB)")

    if args.dry_run:
        cleaned = cleanup_broken(full_name, dry_run=True, as_json=False)
        tuned = load_tunings().get(full_name) if not cli_tuning else cli_tuning
        if not isinstance(tuned, dict) or not tuned:
            tuned = None
        if args.as_json:
            print(json.dumps({
                "status": "ok",
                "dry_run": True,
                "action": "pin",
                "model": full_name,
                "remote_url": remote_url,
                "keepalive": args.keepalive,
                "would_warm": not args.no_warm,
                "would_clean_manifests": cleaned,
                "tunings": tuned,
                "size_gb": round(size_gb, 2)
            }, indent=2))
        else:
            if cleaned:
                print(f"[dry-run] Would remove {cleaned} stale fake local manifest(s) for '{full_name}'.")
            if cli_tuning:
                print(f"[dry-run] Would save tuning for '{full_name}': {json.dumps(cli_tuning)}")
            if not args.no_warm:
                print(f"[dry-run] Would warm '{full_name}' into remote VRAM (keepalive: {args.keepalive}, options: {json.dumps(tuned) if tuned else None})")
            print(f"[dry-run] Would pin '{full_name}' -> {remote_url} (keepalive: {args.keepalive})")
        return 0

    # Normal execution (not dry-run)
    cleaned = cleanup_broken(full_name)
    if cleaned and not args.as_json:
        print(f"[*] Removed {cleaned} stale fake local manifest(s) for '{full_name}'.")

    if cli_tuning:
        save_tuning(full_name, cli_tuning, merge=True)
        if not args.as_json:
            print(f"[+] Saved tuning for '{full_name}': {json.dumps(cli_tuning)}")

    warm_msg = None
    if not args.no_warm:
        if not args.as_json:
            print(f"[*] Warming '{full_name}' into remote VRAM (keep_alive: {args.keepalive})...")
        try:
            tuned = load_tunings().get(full_name)
            if not isinstance(tuned, dict) or not tuned:
                tuned = None
            if tuned and not args.as_json:
                print(f"[*] Applying tuned options {json.dumps(tuned)} to warm request.")
            ok, warm_msg = warm_remote_model(remote_url, full_name, args.keepalive, options=tuned)
            if not args.as_json:
                print(f"[✓] Remote warm: {warm_msg}")
        except Exception as e:
            warm_msg = f"failed: {e}"
            if not args.as_json:
                print(f"[!] Warm failed (model still pinned): {e}", file=sys.stderr)

    spath = None
    try:
        spath = save_pin(full_name, remote_url, args.keepalive, warm=not args.no_warm)
        if not args.as_json:
            print(f"[✓] Pinned '{full_name}' -> {remote_url} (state: {spath})")
    except Exception as e:
        if not args.as_json:
            print(f"[!] Could not persist pin: {e}", file=sys.stderr)

    if args.as_json:
        print(json.dumps({
            "status": "ok",
            "dry_run": False,
            "action": "pin",
            "model": full_name,
            "remote_url": remote_url,
            "keepalive": args.keepalive,
            "warmed": not args.no_warm,
            "warm_status": warm_msg,
            "cleaned_manifests": cleaned,
            "state_file": spath,
            "tunings": cli_tuning or None,
            "size_gb": round(size_gb, 2)
        }, indent=2))
        return 0

    print("    Available at all times via:")
    print(f"      kimo run '{full_name}'")
    print(f"      kimo launch <cli> --model '{full_name}'")
    print(f"      OLLAMA_HOST={remote_url} ollama run '{full_name}'")
    print(f"    Keepalive: systemctl enable --now ollama-stream-keepalive.timer "
          f"(re-warms pins incl. '{full_name}')")
    return 0


if __name__ == "__main__":
    sys.exit(main())
