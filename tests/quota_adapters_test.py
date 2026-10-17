#!/usr/bin/env python3
"""Quota regression tests using isolated credentials and protocol fixtures."""
import argparse
import concurrent.futures
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import io
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("quota", ROOT / "lib/kimo-quota.py")
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kimo-quota-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.environment = patch.dict(os.environ, {"PATH": os.environ.get("PATH", "")}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.which = patch.object(quota.shutil, "which", return_value="/fixture/cli")
        self.which.start()
        self.addCleanup(self.which.stop)
        self.args = argparse.Namespace(home=str(self.home), model="", timeout=1, offline=False,
            host_mode="auto", local_url="http://127.0.0.1:11434", remote_url="http://remote.invalid:11434",
            target_host="", multi_hosts="", web_url="http://127.0.0.1:23456/command")
        self.dashboard = quota.Dashboard(self.args)
        # All HTTP and native commands must be explicitly mocked by a test.
        self.http = patch.object(quota, "fetch_json", side_effect=AssertionError("unexpected HTTP request"))
        self.http_mock = self.http.start()
        self.addCleanup(self.http.stop)
        self.command = patch.object(quota, "command_json", side_effect=AssertionError("unexpected CLI command"))
        self.command_mock = self.command.start()
        self.addCleanup(self.command.stop)
        self.grok = patch.object(quota, "grok_limits", side_effect=quota.QuotaError("unavailable", "Native fixture unavailable."))
        self.grok_mock = self.grok.start()
        self.addCleanup(self.grok.stop)

    def file(self, relative, value):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        return path

    def http_payload(self, payload):
        self.http_mock.side_effect = None
        self.http_mock.return_value = payload

    def command_payload(self, payload):
        self.command_mock.side_effect = None
        self.command_mock.return_value = payload

    def test_zero_remaining_and_unknown_are_distinct(self):
        exhausted = quota.window("requests", used=100, limit=100, remaining=0)
        self.assertEqual(exhausted["remaining_percent"], 0)
        self.assertEqual(exhausted["remaining"], 0)
        self.assertIsNone(quota.window("unknown")["remaining"])
        self.assertIsNone(quota.window("unknown")["remaining_percent"])
        self.assertIsNone(quota.number(True))
        self.assertIsNone(quota.number("NaN"))

    def test_codex_multiple_pools_and_resets(self):
        windows = quota.codex_windows({"rateLimitsByLimitId": {
            "codex": {"primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 12345}},
            "review": {"secondary": {"usedPercent": 20}}}})
        self.assertEqual([w["remaining_percent"] for w in windows], [0, 80])
        self.assertEqual(windows[0]["resets_at"], 12345)

    def test_codex_legacy_single_pool(self):
        windows = quota.codex_windows({"rateLimits": {"primary": {"usedPercent": 50}}})
        self.assertEqual(windows[0]["remaining_percent"], 50)

    def test_claude_cached_oauth_and_secret_is_not_reported(self):
        secret = "fixture-claude-token"
        self.file(".claude/.credentials.json", {"claudeAiOauth": {"accessToken": secret}})
        self.http_payload({"five_hour": {"utilization": 45, "resets_at": "2026-10-12T10:00:00Z"},
                           "seven_day": {"utilization": 100}})
        data = self.dashboard.cli("claude")
        self.assertEqual(data["windows"][0]["remaining_percent"], 55)
        self.assertEqual(data["windows"][1]["remaining_percent"], 0)
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer " + secret)
        self.assertNotIn(secret, json.dumps(data))

    def test_claude_api_key_does_not_masquerade_as_subscription_auth(self):
        os.environ["ANTHROPIC_API_KEY"] = "fixture-api-key"
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.http_mock.assert_not_called()

    def claude_token(self, expires=None, **overrides):
        token = {"accessToken": "fixture-claude-old", "refreshToken": "fixture-claude-refresh",
                 "expiresAt": expires if expires is not None else (time.time() + 3600) * 1000,
                 "refreshTokenExpiresAt": (time.time() + 86_400) * 1000,
                 "scopes": ["user:profile", "user:inference"], "subscriptionType": "pro", "rateLimitTier": "fixture-tier",
                 **overrides}
        return self.file(".claude/.credentials.json", {"claudeAiOauth": token, "mcpOAuth": {"fixture": {"accessToken": "fixture-mcp"}}})

    def claude_refresh_response(self, **overrides):
        return {"access_token": "fixture-claude-new", "refresh_token": "fixture-claude-rotated",
                "expires_in": 3600, "refresh_token_expires_in": 86_400,
                "scope": "user:profile user:inference", **overrides}

    def assert_claude_refresh_cleaned_up(self, path):
        self.assertFalse(list(path.parent.glob(".kimo-refresh-*")))
        self.assertFalse((path.parent / ".oauth_refresh.lock").exists())
        self.assertFalse((path.parent / ".storage-write.lock").exists())
        self.assertFalse(Path(str(path.parent.resolve()) + ".lock").exists())

    def test_claude_expired_token_refresh_preserves_other_credentials(self):
        path = self.claude_token(expires=1)
        self.http_mock.side_effect = [self.claude_refresh_response(), {"five_hour": {"utilization": 20}}]
        data = self.dashboard.cli("claude")
        self.assertEqual(data["status"], "online")
        self.assertEqual(data["windows"][0]["remaining_percent"], 80)
        self.assertEqual(data["plan"], "pro")
        self.assertTrue(data["auth"]["refreshed"])
        refresh = self.http_mock.call_args_list[0]
        self.assertEqual(refresh.args[0], "https://platform.claude.com/v1/oauth/token")
        self.assertEqual(refresh.kwargs["body"]["grant_type"], "refresh_token")
        self.assertEqual(refresh.kwargs["body"]["scope"], "user:profile user:inference")
        self.assertNotIn("form", refresh.kwargs)
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer fixture-claude-new")
        stored = json.loads(path.read_text())
        self.assertEqual(stored["mcpOAuth"], {"fixture": {"accessToken": "fixture-mcp"}})
        self.assertEqual(stored["claudeAiOauth"]["refreshToken"], "fixture-claude-rotated")
        self.assertGreater(stored["claudeAiOauth"]["expiresAt"], time.time() * 1000)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-claude-new", json.dumps(data))
        self.assertNotIn("fixture-mcp", json.dumps(data))
        self.assert_claude_refresh_cleaned_up(path)

    def test_claude_refreshes_within_native_five_minute_threshold(self):
        self.claude_token(expires=(time.time() + 60) * 1000)
        self.http_mock.side_effect = [self.claude_refresh_response(), {"five_hour": {"utilization": 0}}]
        self.assertTrue(self.dashboard.cli("claude")["auth"]["refreshed"])

    def test_claude_401_refreshes_once_and_retries(self):
        self.claude_token()
        self.http_mock.side_effect = [quota.QuotaError("auth_required", "HTTP 401", 401),
                                     self.claude_refresh_response(), {"seven_day": {"utilization": 40}}]
        self.assertEqual(self.dashboard.cli("claude")["status"], "online")
        self.assertEqual(self.http_mock.call_count, 3)

    def test_claude_second_401_does_not_loop(self):
        path = self.claude_token()
        self.http_mock.side_effect = [quota.QuotaError("auth_required", "HTTP 401", 401),
                                     self.claude_refresh_response(), quota.QuotaError("auth_required", "HTTP 401", 401)]
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.assertEqual(self.http_mock.call_count, 3)
        self.assertEqual(json.loads(path.read_text())["claudeAiOauth"]["accessToken"], "fixture-claude-new")

    def test_claude_403_and_429_do_not_rotate_tokens(self):
        path = self.claude_token()
        original = path.read_bytes()
        for status, code in (("auth_required", 403), ("rate_limited", 429)):
            self.http_mock.reset_mock()
            self.http_mock.side_effect = quota.QuotaError(status, "Fixture request failed", code)
            self.assertEqual(self.dashboard.cli("claude")["status"], status)
            self.assertEqual(self.http_mock.call_count, 1)
        self.assertEqual(path.read_bytes(), original)

    def test_claude_no_refresh_leaves_expired_credentials_untouched(self):
        path = self.claude_token(expires=1)
        original = path.read_bytes()
        self.args.no_refresh = True
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.http_mock.assert_not_called()
        self.assertEqual(path.read_bytes(), original)

    def test_claude_no_refresh_still_reads_valid_token(self):
        self.claude_token(expires=(time.time() + 60) * 1000)
        self.args.no_refresh = True
        self.http_payload({"five_hour": {"utilization": 100}})
        data = self.dashboard.cli("claude")
        self.assertEqual(data["windows"][0]["remaining_percent"], 0)
        self.assertFalse(data["auth"]["refreshed"])
        self.assertEqual(self.http_mock.call_count, 1)

    def test_claude_env_token_never_refreshes_or_reads_another_login(self):
        path = self.claude_token(expires=1)
        original = path.read_bytes()
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "fixture-explicit-token"
        self.http_mock.side_effect = quota.QuotaError("auth_required", "HTTP 401", 401)
        with patch.object(quota, "read_json", side_effect=AssertionError("cached login must not be read")):
            self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.assertEqual(self.http_mock.call_count, 1)
        self.assertEqual(path.read_bytes(), original)

    def test_claude_profile_scope_is_required_for_usage(self):
        self.claude_token(scopes=["user:inference"])
        data = self.dashboard.cli("claude")
        self.assertEqual(data["status"], "auth_required")
        self.assertIn("user:profile", data["message"])
        self.http_mock.assert_not_called()

    def test_claude_expired_refresh_token_requires_login_without_network(self):
        self.claude_token(expires=1, refreshTokenExpiresAt=1)
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.http_mock.assert_not_called()

    def test_claude_secure_storage_directory_overrides_settings_directory(self):
        self.claude_token()
        other = self.file("other/.credentials.json", {"claudeAiOauth": {"accessToken": "fixture-secure"}})
        os.environ.update(CLAUDE_CONFIG_DIR=str(self.home / ".claude"), CLAUDE_SECURESTORAGE_CONFIG_DIR=str(other.parent))
        self.http_payload({"five_hour": {"utilization": 0}})
        self.assertEqual(self.dashboard.cli("claude")["status"], "online")
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer fixture-secure")
        os.environ["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
        self.assertEqual(quota.claude_directory(self.home), self.home / ".claude")

    def test_claude_cached_client_id_is_used_during_refresh(self):
        self.claude_token(expires=1, clientId="fixture-client-id")
        self.http_mock.side_effect = [self.claude_refresh_response(), {"five_hour": {"utilization": 0}}]
        self.assertEqual(self.dashboard.cli("claude")["status"], "online")
        self.assertEqual(self.http_mock.call_args_list[0].kwargs["body"]["client_id"], "fixture-client-id")

    def test_claude_refresh_without_rotation_keeps_existing_refresh_token(self):
        path = self.claude_token(expires=1)
        response = self.claude_refresh_response()
        del response["refresh_token"]
        self.http_mock.side_effect = [response, {"five_hour": {"utilization": 0}}]
        self.assertEqual(self.dashboard.cli("claude")["status"], "online")
        self.assertEqual(json.loads(path.read_text())["claudeAiOauth"]["refreshToken"], "fixture-claude-refresh")

    def test_claude_refresh_failures_preserve_credentials_and_clean_up(self):
        path = self.claude_token(expires=1)
        original = path.read_bytes()
        for response in (quota.QuotaError("unavailable", "HTTP 400", 400), quota.QuotaError("timeout", "Fixture timeout"),
                         {"access_token": "fixture-incomplete"}):
            self.http_mock.side_effect = response if isinstance(response, Exception) else None
            self.http_mock.return_value = response
            self.assertIn(self.dashboard.cli("claude")["status"], ("auth_required", "timeout"))
            self.assertEqual(path.read_bytes(), original)
            self.assert_claude_refresh_cleaned_up(path)

    def test_claude_writable_storage_checked_before_rotating(self):
        path = self.claude_token(expires=1)
        original = path.read_bytes()
        with patch.object(quota.tempfile, "mkstemp", side_effect=PermissionError("Fixture")):
            self.assertEqual(self.dashboard.cli("claude")["status"], "unavailable")
        self.http_mock.assert_not_called()
        self.assertEqual(path.read_bytes(), original)
        self.assert_claude_refresh_cleaned_up(path)

    def test_claude_concurrent_refreshes_coalesce(self):
        self.claude_token(expires=1)
        refreshes = []
        def response(url, *args, **kwargs):
            if url.endswith("/v1/oauth/token"):
                refreshes.append(url)
                time.sleep(.05)
                return self.claude_refresh_response()
            return {"five_hour": {"utilization": 5}}
        self.http_mock.side_effect = response
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(self.dashboard.cli, ("claude", "claude")))
        self.assertEqual(len(refreshes), 1)
        self.assertTrue(all(result["status"] == "online" for result in results))

    def test_claude_native_lock_contention_is_bounded(self):
        path = self.claude_token(expires=1)
        original = path.read_bytes()
        for lock in (path.parent / ".oauth_refresh.lock", Path(str(path.parent.resolve()) + ".lock"), path.parent / ".storage-write.lock"):
            lock.mkdir()
            dashboard = quota.Dashboard(self.args)
            dashboard.args.timeout = .025
            self.assertEqual(dashboard.cli("claude")["status"], "timeout")
            self.assertTrue(lock.exists())
            lock.rmdir()
        self.http_mock.assert_not_called()
        self.assertEqual(path.read_bytes(), original)

    def test_claude_stale_refresh_lock_is_recovered(self):
        path = self.claude_token(expires=1)
        lock = path.parent / ".oauth_refresh.lock"
        lock.mkdir()
        os.utime(lock, (time.time() - 65, time.time() - 65))
        self.http_mock.side_effect = [self.claude_refresh_response(), {"five_hour": {"utilization": 0}}]
        self.assertEqual(self.dashboard.cli("claude")["status"], "online")
        self.assert_claude_refresh_cleaned_up(path)

    def test_claude_refresh_does_not_resurrect_logged_out_account(self):
        path = self.claude_token(expires=1)
        def logout(*args, **kwargs):
            path.unlink()
            return self.claude_refresh_response()
        self.http_mock.side_effect = logout
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.assertFalse(path.exists())
        self.assert_claude_refresh_cleaned_up(path)

    def test_claude_refresh_does_not_overwrite_a_new_login(self):
        path = self.claude_token(expires=1)
        newer = {"claudeAiOauth": {"accessToken": "fixture-new-login", "refreshToken": "fixture-other-account"}}
        def relogin(*args, **kwargs):
            path.write_text(json.dumps(newer))
            return self.claude_refresh_response()
        self.http_mock.side_effect = relogin
        self.assertEqual(self.dashboard.cli("claude")["status"], "auth_required")
        self.assertEqual(json.loads(path.read_text()), newer)

    def test_claude_symlink_credentials_are_not_replaced_during_refresh(self):
        path = self.claude_token(expires=1)
        target = path.with_name("fixture-credentials.json")
        path.rename(target)
        path.symlink_to(target.name)
        self.assertEqual(self.dashboard.cli("claude")["status"], "unavailable")
        self.http_mock.assert_not_called()
        self.assertTrue(path.is_symlink())

    def test_claude_modern_scoped_limits_precede_legacy_duplicates(self):
        data = quota.claude_usage({"five_hour": {"utilization": 25}, "limits": [None,
            {"kind": "session", "percent": 25, "resets_at": "fixture-reset", "is_active": True},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 100,
             "scope": {"model": {"display_name": "Sonnet", "id": "private-model"}, "surface": {"display_name": "Code"}}}]})
        self.assertEqual(len(data["windows"]), 2)
        self.assertEqual(data["windows"][0]["remaining_percent"], 75)
        self.assertEqual(data["windows"][1]["model"], "Sonnet")
        self.assertEqual(data["windows"][1]["remaining_percent"], 0)
        self.assertNotIn("private-model", json.dumps(data))

    def test_claude_extra_usage_money_conversion_and_disabled_allowance(self):
        data = quota.claude_usage({"extra_usage": {"is_enabled": True, "monthly_limit": 5000,
            "used_credits": 1250, "utilization": 25, "currency": "usd"}})
        window = data["windows"][0]
        self.assertEqual((window["limit"], window["used"], window["remaining"], window["unit"]), (50, 12.5, 37.5, "USD"))
        data = quota.claude_usage({"extra_usage": {"is_enabled": False, "monthly_limit": 5000, "used_credits": 0}})
        self.assertEqual(data["extra_usage"]["monthly_limit"], 50)
        self.assertIsNone(data["windows"][0]["remaining"])
        unlimited = quota.claude_usage({"extra_usage": {"is_enabled": True, "monthly_limit": None, "used_credits": 0, "utilization": 0}})
        self.assertIsNone(unlimited["windows"][0]["remaining_percent"])
        yen = quota.claude_usage({"extra_usage": {"is_enabled": True, "monthly_limit": 5000, "used_credits": 1000, "currency": "JPY"}})
        self.assertEqual(yen["windows"][0]["remaining"], 4000)
        self.assertEqual(quota.claude_usage({"limits": [{"kind": "weekly_all", "percent": 0}]})["windows"][0]["name"], "7-day quota")

    def test_claude_model_filter_retains_account_windows(self):
        self.claude_token()
        self.args.model = "sonnet"
        self.dashboard = quota.Dashboard(self.args)
        self.http_payload({"five_hour": {"utilization": 10}, "seven_day_opus": {"utilization": 20}, "seven_day_sonnet": {"utilization": 30}})
        data = self.dashboard.cli("claude")
        self.assertEqual([window["name"] for window in data["windows"]], ["5-hour quota", "7-day Sonnet quota"])

    def test_auth_failure_is_isolated_and_does_not_echo_secret(self):
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "fixture-secret"
        self.http_mock.side_effect = quota.QuotaError("auth_required", "Usage service returned HTTP 401.")
        data = self.dashboard.cli("claude")
        self.assertEqual(data["status"], "auth_required")
        self.assertNotIn("fixture-secret", json.dumps(data))
        self.assertEqual(self.dashboard.cli("grok")["status"], "unavailable")

    def test_kimi_cached_token_and_modern_ratio(self):
        self.file(".kimi-code/credentials/kimi-code.json", {"access_token": "fixture-kimi"})
        self.http_payload({"usages": {"limit_5h": {"used_ratio": .75, "reset_time": 1234},
                                     "limit_7d": {"used_ratio": 0}}})
        data = self.dashboard.cli("kimi")
        self.assertEqual([w["remaining_percent"] for w in data["windows"]], [25, 100])
        self.assertNotIn("fixture-kimi", json.dumps(data))

    def test_kimi_legacy_summary_and_five_hour_window(self):
        windows = quota.kimi_windows({"usage": {"used": 60, "limit": 100, "remaining": 40},
            "limits": [{"window": {"duration": 5, "timeUnit": "HOUR"},
                        "detail": {"used": 10, "limit": 10, "remaining": 0}}]})
        self.assertEqual([w["remaining_percent"] for w in windows], [40, 0])

    def test_grok_live_billing_included_on_demand_and_prepaid(self):
        self.grok_mock.side_effect = None
        self.grok_mock.return_value = {"subscription_tier": "SuperGrok", "on_demand_enabled": False,
            "config": {"creditUsagePercent": 100, "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": "2026-10-05T00:00:00Z", "end": "2026-10-12T00:00:00Z"},
                "onDemandCap": {"val": 5000}, "onDemandUsed": {"val": 300}, "prepaidBalance": {},
                "isUnifiedBillingUser": True, "secret": "fixture-do-not-output",
                "history": [{"billingCycle": {"year": 2026, "month": 9}, "totalUsed": {"val": 1234}}]}}
        data = self.dashboard.cli("grok")
        self.assertEqual(data["status"], "online")
        self.assertEqual(data["plan"], "SuperGrok")
        self.assertEqual([w["remaining"] for w in data["windows"]], [None, 47, 0])
        self.assertEqual(data["windows"][0]["remaining_percent"], 0)
        self.assertEqual(data["windows"][0]["resets_at"], "2026-10-12T00:00:00Z")
        self.assertFalse(data["billing"]["on_demand_enabled"])
        self.assertEqual(data["history"][0]["total_used_usd"], 12.34)
        self.assertNotIn("fixture-do-not-output", json.dumps(data))
        self.assertEqual(self.grok_mock.call_args.args[2], self.home / ".grok")

    def test_grok_legacy_cents_and_unknown_balance(self):
        data = quota.grok_billing({"config": {"monthlyLimit": {"val": 1000}, "used": {"val": 500},
                                               "billingPeriodEnd": "2026-11-01"}})
        self.assertEqual(data["windows"][0]["remaining"], 5)
        self.assertEqual(data["windows"][0]["remaining_percent"], 50)
        self.assertEqual(quota.grok_billing({"config": None})["status"], "unavailable")
        self.assertEqual(quota.grok_billing({"config": {}})["windows"], [])

    def test_grok_new_percentage_wins_over_legacy_amounts(self):
        data = quota.grok_billing({"config": {"creditUsagePercent": 25,
            "monthlyLimit": {"val": 100}, "used": {"val": 99}}})
        self.assertEqual(data["windows"][0]["remaining_percent"], 75)
        self.assertIsNone(data["windows"][0]["limit"])

    def test_grok_backend_fallback_keeps_subscription_failure(self):
        os.environ["GROK_MODELS_BASE_URL"] = self.args.local_url + "/v1"
        data = self.dashboard.cli("grok")
        self.assertEqual(data["status"], "not_metered")
        self.assertEqual(data["scope"], "backend")
        self.assertEqual(data["subscription_status"], "unavailable")

    def kimi_config(self, base="https://api.kimi.ai/coding/v1", host="https://auth.kimi.ai"):
        directory = self.home / ".kimi-code"
        directory.mkdir(exist_ok=True)
        encoded = json.dumps({"oauthHost": host, "baseUrl": base}, separators=(",", ":"))
        storage = "kimi-code-env-" + quota.hashlib.sha256(encoded.encode()).hexdigest()[:16]
        if base == "https://api.kimi.com/coding/v1" and host == "https://auth.kimi.com":
            storage = "kimi-code"
        (directory / "config.toml").write_text('[providers."managed:kimi-code"]\n'
            f'base_url = "{base}"\n[providers."managed:kimi-code".oauth]\n'
            f'key = "oauth/{storage}"\noauth_host = "{host}"\n')
        return ".kimi-code/credentials/" + storage + ".json"

    def test_kimi_global_slot_ignores_expired_mainland_credentials(self):
        selected = self.kimi_config()
        self.file(selected, {"access_token": "fixture-global", "expires_at": time.time() + 3600})
        self.file(".kimi-code/credentials/kimi-code.json", {"access_token": "fixture-wrong-region", "expires_at": 1})
        self.http_payload({"usages": {"limit_month_code": {"used_ratio": .9}}})
        data = self.dashboard.cli("kimi")
        self.assertEqual(data["status"], "online")
        self.assertEqual(data["auth"]["region"], "global")
        self.assertEqual(self.http_mock.call_args.args[0], "https://api.kimi.ai/coding/v1/usages")
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer fixture-global")
        self.assertNotIn("fixture-global", json.dumps(data))

    def test_kimi_global_missing_slot_never_falls_back_to_mainland_token(self):
        self.kimi_config()
        self.file(".kimi-code/credentials/kimi-code.json", {"access_token": "fixture-wrong-region"})
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.http_mock.assert_not_called()

    def test_kimi_environment_endpoints_select_separate_credentials(self):
        self.kimi_config()
        os.environ.update(KIMI_CODE_BASE_URL="https://api.kimi.com/coding/v1", KIMI_CODE_OAUTH_HOST="https://auth.kimi.com")
        self.file(".kimi-code/credentials/kimi-code.json", {"access_token": "fixture-mainland"})
        self.http_payload({"usages": {"limit_5h": {"used_ratio": .2}}})
        self.assertEqual(self.dashboard.cli("kimi")["auth"]["region"], "mainland-cn")
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer fixture-mainland")

    def test_kimi_region_marker_selects_global_slot_without_config(self):
        auth_path = self.kimi_config()
        (self.home / ".kimi-code/config.toml").unlink()
        (self.home / ".kimi-code/region").write_text("global\n")
        self.file(auth_path, {"access_token": "fixture-global"})
        self.http_payload({"usages": {"limit_5h": {"used_ratio": .2}}})
        self.assertEqual(self.dashboard.cli("kimi")["auth"]["region"], "global")

    def test_kimi_rejects_unsafe_oauth_slot(self):
        self.kimi_config()
        path = self.home / ".kimi-code/config.toml"
        path.write_text(path.read_text().replace('key = "oauth/kimi-code-env-', 'key = "oauth/../kimi-code-env-'))
        self.assertEqual(self.dashboard.cli("kimi")["status"], "unavailable")
        self.http_mock.assert_not_called()

    def test_kimi_http_endpoint_requires_tls_outside_localhost(self):
        os.environ["KIMI_CODE_BASE_URL"] = "http://example.invalid/coding/v1"
        os.environ["KIMI_CODE_API_KEY"] = "fixture-never-send"
        self.assertEqual(self.dashboard.cli("kimi")["status"], "unavailable")
        self.http_mock.assert_not_called()

    def test_kimi_expired_oauth_refreshes_atomically_and_reuses_new_token(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        self.http_mock.side_effect = [{"access_token": "fixture-new", "refresh_token": "fixture-new-refresh", "expires_in": 3600},
                                     {"usages": {"limit_5h": {"used_ratio": .5}}}]
        data = self.dashboard.cli("kimi")
        self.assertEqual(data["status"], "online")
        self.assertTrue(data["auth"]["refreshed"])
        self.assertEqual(self.http_mock.call_args_list[0].args[0], "https://auth.kimi.com/api/oauth/token")
        self.assertTrue(self.http_mock.call_args_list[0].kwargs["form"])
        self.assertEqual(self.http_mock.call_args.args[2]["Authorization"], "Bearer fixture-new")
        self.assertEqual(json.loads(path.read_text())["refresh_token"], "fixture-new-refresh")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(path.parent.glob(".kimo-refresh-*")))
        self.assertFalse(list((self.home / ".kimi-code/oauth").glob("*.lock")))
        self.assertNotIn("fixture-new", json.dumps(data))

    def test_kimi_unexpected_401_refreshes_once_then_retries(self):
        self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": time.time() + 3600})
        self.http_mock.side_effect = [quota.QuotaError("auth_required", "HTTP 401", 401),
            {"access_token": "fixture-new", "refresh_token": "fixture-new-refresh", "expires_in": 3600},
            {"usages": {"limit_5h": {"used_ratio": .1}}}]
        self.assertEqual(self.dashboard.cli("kimi")["status"], "online")
        self.assertEqual(self.http_mock.call_count, 3)

    def test_kimi_refresh_rejection_preserves_existing_credentials(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        before = path.read_bytes()
        self.http_mock.side_effect = quota.QuotaError("unavailable", "HTTP 400", 400)
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(list(path.parent.glob(".kimo-refresh-*")))

    def test_kimi_incomplete_refresh_does_not_replace_file(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        self.http_payload({"access_token": "fixture-new", "expires_in": 3600})
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.assertEqual(json.loads(path.read_text())["access_token"], "fixture-old")

    def test_kimi_no_refresh_never_rotates_expired_token(self):
        self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        self.args.no_refresh = True
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.http_mock.assert_not_called()
        self.assertFalse((self.home / ".kimi-code/oauth").exists())

    def test_kimi_api_key_never_triggers_oauth_refresh(self):
        os.environ["KIMI_CODE_API_KEY"] = "fixture-api-key"
        self.http_mock.side_effect = quota.QuotaError("auth_required", "HTTP 401", 401)
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.assertEqual(self.http_mock.call_count, 1)
        self.assertFalse((self.home / ".kimi-code/oauth").exists())

    def test_kimi_concurrent_refresh_is_coalesced(self):
        self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        refreshes = []
        def response(url, *args, **kwargs):
            if url.endswith("/api/oauth/token"):
                refreshes.append(url)
                time.sleep(.1)
                return {"access_token": "fixture-new", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
            return {"usages": {"limit_5h": {"used_ratio": .2}}}
        self.http_mock.side_effect = response
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(self.dashboard.cli, ("kimi", "kimi")))
        self.assertEqual(len(refreshes), 1)
        self.assertTrue(all(result["status"] == "online" for result in results))

    def test_kimi_existing_native_lock_blocks_refresh_without_rotating(self):
        self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        (self.home / ".kimi-code/oauth/kimi-code.lock").mkdir(parents=True)
        self.args.timeout = .05
        self.assertEqual(self.dashboard.cli("kimi")["status"], "timeout")
        self.http_mock.assert_not_called()

    def test_kimi_stale_native_lock_is_recovered(self):
        self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        lock = self.home / ".kimi-code/oauth/kimi-code.lock"
        lock.mkdir(parents=True)
        os.utime(lock, (time.time() - 10, time.time() - 10))
        self.http_mock.side_effect = [{"access_token": "fixture-new", "refresh_token": "fixture-new-refresh", "expires_in": 3600},
                                     {"usages": {"limit_5h": {"used_ratio": 0}}}]
        self.assertEqual(self.dashboard.cli("kimi")["status"], "online")
        self.assertFalse(lock.exists())

    def test_kimi_refresh_checks_writable_storage_before_rotating(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        original = path.read_bytes()
        with patch.object(quota.tempfile, "mkstemp", side_effect=PermissionError("fixture")):
            self.assertEqual(self.dashboard.cli("kimi")["status"], "unavailable")
        self.http_mock.assert_not_called()
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((self.home / ".kimi-code/oauth/kimi-code.lock").exists())

    def test_kimi_refresh_does_not_resurrect_logged_out_account(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        def logout(*args, **kwargs):
            path.unlink()
            return {"access_token": "fixture-new", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        self.http_mock.side_effect = logout
        self.assertEqual(self.dashboard.cli("kimi")["status"], "auth_required")
        self.assertFalse(path.exists())
        self.assertFalse(list(path.parent.glob(".kimo-refresh-*")))

    def test_kimi_refresh_preserves_credentials_on_timeout(self):
        path = self.file(".kimi-code/credentials/kimi-code.json", {
            "access_token": "fixture-old", "refresh_token": "fixture-refresh", "expires_at": 1})
        original = path.read_bytes()
        self.http_mock.side_effect = quota.QuotaError("timeout", "Fixture timeout")
        self.assertEqual(self.dashboard.cli("kimi")["status"], "timeout")
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(list(path.parent.glob(".kimo-refresh-*")))

    def test_kimi_wallet_fixed_point_amounts_and_monthly_cap(self):
        wallet, windows = quota.kimi_wallet({"booster_wallet": {
            "balance": {"type": "BOOSTER", "amount": "1000000000", "amountLeft": "125000000"},
            "monthlyChargeLimitEnabled": True, "monthlyChargeLimit": {"priceInCents": "5000", "currency": "USD"},
            "monthlyUsed": {"priceInCents": "4000", "currency": "USD"}}})
        self.assertEqual(wallet["balance"], 1.25)
        self.assertEqual(wallet["total"], 10)
        self.assertEqual(windows[0]["remaining"], 1.25)
        self.assertEqual(windows[1]["remaining"], 10)
        zero, windows = quota.kimi_wallet({"boosterWallet": {"balance": {"type": "BOOSTER"}}})
        self.assertEqual(zero["balance"], 0)
        self.assertEqual(windows[0]["remaining"], 0)
        self.assertEqual(quota.kimi_wallet({}), (None, []))

    def test_kimi_modern_windows_do_not_duplicate_legacy_limit(self):
        windows = quota.kimi_windows({"usages": {"limit_5h": {"used_ratio": 0}},
            "limits": [{"window": {"duration": 300}, "detail": {"limit": "100", "remaining": "100"}}]})
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["name"], "5-hour quota")

    def test_kimi_disabled_cap_does_not_invent_monthly_remaining(self):
        wallet, windows = quota.kimi_wallet({"boosterWallet": {"balance": {"type": "BOOSTER"},
            "monthlyChargeLimitEnabled": False, "monthlyChargeLimit": {"priceInCents": "5000", "currency": "USD"},
            "monthlyUsed": {"priceInCents": "4000", "currency": "USD"}}})
        self.assertEqual(wallet["monthly_limit"], 50)
        self.assertEqual(windows[1]["used"], 40)
        self.assertIsNone(windows[1]["remaining"])
        self.assertIsNone(windows[1]["limit"])

    def test_grok_and_kimi_text_outputs_account_details(self):
        stream = io.StringIO()
        result = {"timestamp": "fixture", "providers": {}, "clis": {"grok": quota.grok_billing({
            "subscription_tier": "SuperGrok", "config": {"creditUsagePercent": 100,
            "currentPeriod": {"start": "2026-10-01", "end": "2026-11-01"}, "prepaidBalance": {}}})}}
        with patch("sys.stdout", stream):
            quota.display(result)
        text = stream.getvalue()
        self.assertIn("Plan: SuperGrok", text)
        self.assertIn("0.0% left", text)
        self.assertIn("0 USD left", text)
        self.assertIn("Billing period:", text)
        wallet, windows = quota.kimi_wallet({"booster_wallet": {"balance": {"type": "BOOSTER"}}})
        result["clis"] = {"kimi": {"status": "online", "windows": windows, "extra_usage": wallet}}
        stream = io.StringIO()
        with patch("sys.stdout", stream):
            quota.display(result)
        self.assertIn("Extra-usage balance: 0 USD left", stream.getvalue())
        self.assertIn("monthly spending cap: disabled", stream.getvalue())

    def test_text_output_hides_missing_and_unavailable_clis(self):
        result = {"timestamp": "fixture", "providers": {}, "clis": {
            "claude": {"status": "online", "windows": []}, "codex": {"status": "rate_limited", "windows": []},
            "hermes": {"status": "not_installed", "windows": []}, "qwen": {"status": "unavailable", "windows": []},
            "kimi": {"status": "auth_required", "windows": []}}}
        for show_all, shown in ((False, {"claude", "codex"}), (True, set(result["clis"]))):
            stream = io.StringIO()
            with patch("sys.stdout", stream):
                quota.display(result, show_all=show_all)
            self.assertEqual({line.split(":")[0] for line in stream.getvalue().splitlines()
                              if line.split(":")[0] in result["clis"]}, shown)

    def test_github_checks_api_rate_limit_only(self):
        self.command_payload({"resources": {"core": {"limit": 5000, "used": 5000, "remaining": 0, "reset": 1234}}})
        data = self.dashboard.cli("gh")
        self.assertEqual(self.command_mock.call_args.args[0][1:], ["api", "rate_limit"])
        self.assertEqual(data["windows"][0]["remaining"], 0)
        self.assertIn("Copilot", data["message"])

    def test_openclaw_provider_windows(self):
        self.command_payload({"usage": {"providers": [{"provider": "codex", "windows": [
            {"label": "5h", "usedPercent": 33, "resetAt": 1234000}], "billing": [
                {"type": "balance", "amount": 0, "unit": "credits"},
                {"type": "budget", "used": 10, "limit": 50, "unit": "USD"}]},
            {"provider": "failed", "error": "fixture", "windows": []}]}})
        data = self.dashboard.cli("openclaw")
        self.assertEqual(data["windows"][0]["remaining_percent"], 67)
        self.assertEqual(data["windows"][0]["resets_at"], 1234)
        self.assertEqual(data["windows"][1]["remaining"], 0)
        self.assertEqual(data["windows"][2]["remaining"], 40)
        self.assertEqual(self.command_mock.call_args.args[0][1:], ["status", "--usage", "--json"])

    def test_cursor_pagination_and_enforced_limit(self):
        os.environ["CURSOR_ADMIN_API_KEY"] = "fixture-cursor"
        self.http_mock.side_effect = [
            {"totalPages": 2, "teamMemberSpend": [{"email": "private@example.invalid", "spendCents": 2500,
                "monthlyLimitDollars": 200, "effectivePerUserLimitDollars": 100}]},
            {"totalPages": 2, "teamMemberSpend": [{"spendCents": 0, "effectivePerUserLimitDollars": 0}]}]
        data = self.dashboard.cli("cursor")
        self.assertEqual(self.http_mock.call_count, 2)
        self.assertEqual(data["windows"][0]["remaining"], 75)
        self.assertEqual(data["windows"][1]["remaining"], 0)
        self.assertEqual(data["scope"], "team")
        self.assertNotIn("private@example.invalid", json.dumps(data))

    def test_cursor_missing_spend_stays_unknown(self):
        os.environ["CURSOR_ADMIN_API_KEY"] = "fixture-cursor"
        self.http_payload({"teamMemberSpend": [{"effectivePerUserLimitDollars": 100}]})
        data = self.dashboard.cli("cursor")
        self.assertIsNone(data["windows"][0]["remaining"])

    def test_cursor_personal_token_is_not_sent_to_admin_api(self):
        os.environ["CURSOR_API_KEY"] = "fixture-personal"
        self.assertEqual(self.dashboard.cli("cursor")["status"], "unavailable")
        self.http_mock.assert_not_called()

    def test_google_quota_project_and_model_filter(self):
        self.file(".gemini/antigravity-cli/antigravity-oauth-token", {"token": {"access_token": "fixture-google"}})
        os.environ["GOOGLE_CLOUD_PROJECT"] = "fixture-project"
        self.args.model = "pro"
        self.dashboard = quota.Dashboard(self.args)
        self.http_payload({"buckets": [{"modelId": "gemini-pro", "remainingAmount": "0", "remainingFraction": 0},
                                        {"modelId": "gemini-flash", "remainingFraction": .5}]})
        data = self.dashboard.cli("agy")
        self.assertEqual(len(data["windows"]), 1)
        self.assertEqual(data["windows"][0]["remaining_percent"], 0)
        self.assertEqual(self.http_mock.call_args.args[3], {"project": "fixture-project"})

    def test_qwen_oauth_is_not_bailian_free_tier(self):
        self.file(".qwen/settings.json", {"security": {"auth": {"selectedType": "qwen-oauth"}},
                                          "env": {"DASHSCOPE_API_KEY": "fixture-key"}})
        self.assertEqual(self.dashboard.cli("qwen")["status"], "unavailable")
        self.command_mock.assert_not_called()

    def test_google_discovers_existing_consumer_quota_project(self):
        self.file(".gemini/antigravity-cli/antigravity-oauth-token", {"token": {"access_token": "fixture-google"}})
        self.http_mock.side_effect = [{"cloudaicompanionProject": "existing-project"},
                                     {"buckets": [{"modelId": "pro", "remainingFraction": .25}]}]
        data = self.dashboard.cli("agy")
        self.assertEqual(data["windows"][0]["remaining_percent"], 25)
        self.assertEqual(self.http_mock.call_args.args[3], {"project": "existing-project"})
        self.assertTrue(self.http_mock.call_args_list[0].args[0].endswith(":loadCodeAssist"))

    def test_qwen_bailian_retains_rows_and_actual_unit(self):
        self.file(".qwen/settings.json", {"env": {"OPENAI_BASE_URL": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"}})
        self.command_payload([{"model": "qwen3", "type": "text", "remaining": 100, "expires": "2026-12-01"},
                              {"model": "wan", "type": "image", "unit": "images", "remaining": 0}])
        data = self.dashboard.cli("qwen")
        self.assertEqual(len(data["models"]), 2)
        self.assertEqual(data["windows"][1]["unit"], "images")
        self.assertEqual(data["windows"][0]["unit"], "units")
        self.assertEqual(data["models"][0]["type"], "text")
        self.assertEqual(data["scope"], "provider")

    def test_bailian_error_envelope_is_not_success(self):
        self.command_payload({"error": "fixture-expired"})
        self.assertEqual(self.dashboard.provider("freetier")["status"], "auth_required")

    def test_openrouter_unlimited_and_exhausted_are_distinct(self):
        os.environ["OPENROUTER_API_KEY"] = "fixture-openrouter"
        self.http_payload({"data": {"usage": 25, "limit": None, "limit_remaining": None}})
        self.assertIsNone(self.dashboard.provider("openrouter")["remaining_usd"])
        self.dashboard = quota.Dashboard(self.args)
        self.http_payload({"data": {"usage": 25, "limit": 25, "limit_remaining": 0}})
        self.assertEqual(self.dashboard.provider("openrouter")["remaining_usd"], 0)

    def test_gemini_paginates_without_inventing_account_rate_limits(self):
        os.environ["KIMO_QUOTA_GEMINI_KEY"] = "fixture-gemini"
        self.http_mock.side_effect = [
            {"models": [{"name": "models/gemini-pro", "inputTokenLimit": 1000000}], "nextPageToken": "a b"},
            {"models": [{"name": "models/gemini-flash", "outputTokenLimit": 1000}]}]
        data = self.dashboard.provider("gemini")
        self.assertEqual(len(data["models"]), 2)
        self.assertEqual(data["rate_limits"], {})
        self.assertEqual(data["quota_status"], "unavailable")
        self.assertIn("a%20b", self.http_mock.call_args.args[0])
        self.assertNotIn("fixture-gemini", self.http_mock.call_args.args[0])

    def test_cumulative_timeout_stops_pagination(self):
        os.environ["KIMO_QUOTA_GEMINI_KEY"] = "fixture-gemini"
        self.args.timeout = .01
        def slow_page(*args):
            time.sleep(.02)
            return {"models": [], "nextPageToken": "again"}
        self.http_mock.side_effect = slow_page
        self.assertEqual(self.dashboard.provider("gemini")["status"], "timeout")
        self.assertEqual(self.http_mock.call_count, 1)

    def test_shared_provider_is_requested_once_for_parallel_clis(self):
        os.environ.update(OPENAI_BASE_URL="https://openrouter.ai/api/v1", OPENROUTER_API_KEY="fixture-key")
        self.http_payload({"data": {"usage": 1, "limit": 10}})
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            results = list(executor.map(self.dashboard.cli, ("grok", "hermes", "cyberstrike")))
        self.assertTrue(all(row["status"] == "online" for row in results))
        self.assertEqual(self.http_mock.call_count, 1)

    def test_ollama_custom_routing_and_model_filter(self):
        self.args.host_mode = "custom"
        self.args.target_host = "http://fixture.invalid:1234"
        self.args.model = "pro"
        self.dashboard = quota.Dashboard(self.args)
        self.http_mock.side_effect = [{"version": "fixture"}, {"models": []},
                                     {"models": [{"name": "pro:latest"}, {"name": "other"}]}]
        data = self.dashboard.provider("ollama")
        self.assertEqual(data["hosts"]["custom"]["installed_count"], 1)
        self.assertTrue(all(call.args[0].startswith(self.args.target_host) for call in self.http_mock.call_args_list))
        self.assertEqual(data["quota_status"], "not_metered")

    def test_web_uses_configured_bridge_url(self):
        self.http_payload({"ok": True})
        self.dashboard.provider("web")
        self.assertEqual(self.http_mock.call_args.args[0], "http://127.0.0.1:23456/status")

    def test_offline_avoids_auth_files_and_commands(self):
        self.args.offline = True
        with patch.object(quota, "read_json", side_effect=AssertionError("credential read")):
            for name in quota.GUIDES:
                self.assertEqual(self.dashboard.cli(name)["status"], "offline")
            for name in quota.PROVIDERS:
                self.assertIn(self.dashboard.provider(name)["status"], ("offline", "unconfigured"))
        self.http_mock.assert_not_called()
        self.command_mock.assert_not_called()

    def test_missing_binary_does_not_read_account(self):
        self.which.stop()
        with patch.object(quota.shutil, "which", return_value=None):
            data = self.dashboard.cli("claude")
        self.assertFalse(data["installed"])
        self.assertEqual(data["status"], "not_installed")
        self.http_mock.assert_not_called()

    def test_hermes_local_usage_is_explicitly_session_scoped(self):
        report = self.file("report.json", {"total_tokens": 123, "estimated_cost_usd": .4, "secret": "fixture-hidden"})
        os.environ["HERMES_USAGE_FILE"] = str(report)
        data = self.dashboard.cli("hermes")
        self.assertEqual(data["scope"], "session")
        self.assertEqual(data["status"], "local_usage")
        self.assertNotIn("fixture-hidden", json.dumps(data))

    def test_hermes_dotenv_routes_to_provider_without_execution(self):
        directory = self.home / ".hermes"
        directory.mkdir()
        (directory / ".env").write_text('OPENAI_BASE_URL="https://openrouter.ai/api/v1"\nOPENROUTER_API_KEY=fixture-hermes\n')
        self.http_payload({"data": {"limit": 50, "usage": 10}})
        self.assertEqual(self.dashboard.cli("hermes")["windows"][0]["remaining"], 40)

    def test_opencode_jsonc_selected_provider_and_env_key(self):
        os.environ["FIXTURE_KEY"] = "fixture-opencode"
        directory = self.home / ".config/opencode"
        directory.mkdir(parents=True)
        (directory / "opencode.jsonc").write_text('''{
          // selected provider
          "model": "openrouter/model", "provider": {"openrouter": {"options": {
            "baseURL": "https://openrouter.ai/api/v1", "apiKey": "{env:FIXTURE_KEY}",
          }}},
        }''')
        self.http_payload({"data": {"limit": 100, "usage": 20}})
        data = self.dashboard.cli("opencode")
        self.assertEqual(data["windows"][0]["remaining"], 80)
        self.assertNotIn("fixture-opencode", json.dumps(data))

    def test_other_local_api_is_not_claimed_as_ollama(self):
        os.environ["OPENAI_BASE_URL"] = "http://127.0.0.1:4321/v1"
        self.assertEqual(self.dashboard.cli("cyberstrike")["status"], "unavailable")
        os.environ["OPENAI_BASE_URL"] = self.args.local_url + "/v1"
        self.assertEqual(self.dashboard.cli("cyberstrike")["status"], "not_metered")

    def test_malformed_account_payload_is_contained(self):
        os.environ["KIMI_CODE_API_KEY"] = "fixture-kimi"
        self.http_payload({"limits": [None]})
        self.assertEqual(self.dashboard.cli("kimi")["status"], "unavailable")


class NativeCodexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kimo-codex-protocol-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def executable(self, body):
        path = self.directory / "codex"
        path.write_text("#!" + sys.executable + " -S\n" + body)
        path.chmod(0o755)
        return str(path)

    def test_native_handshake_reads_limits_without_starting_turn(self):
        record = self.directory / "requests.jsonl"
        binary = self.executable('''import json, sys
assert sys.argv[1:] == ["app-server"]
for line in sys.stdin:
    request = json.loads(line)
    with open(''' + repr(str(record)) + ''', "a") as out:
        out.write(line)
    if request.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif request.get("id") == 2:
        print(json.dumps({"id": 2, "result": {"rateLimits": {"primary": {"usedPercent": 20}}}}), flush=True)
''')
        payload = quota.codex_limits(binary, 2)
        requests = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual([r["method"] for r in requests], ["initialize", "initialized", "account/rateLimits/read"])
        self.assertEqual(quota.codex_windows(payload)[0]["remaining_percent"], 80)

    def test_stalled_native_server_is_terminated(self):
        binary = self.executable("import time\ntime.sleep(60)\n")
        start = time.monotonic()
        with self.assertRaises(quota.QuotaError) as raised:
            quota.codex_limits(binary, .1)
        self.assertEqual(raised.exception.status, "timeout")
        self.assertLess(time.monotonic() - start, 2)

    def test_closed_server_returns_unavailable(self):
        binary = self.executable("print('invalid fixture json', flush=True)\n")
        with self.assertRaises(quota.QuotaError) as raised:
            quota.codex_limits(binary, 1)
        self.assertEqual(raised.exception.status, "unavailable")

    def test_grok_native_billing_protocol_without_session_or_prompt(self):
        record = self.directory / "requests.jsonl"
        binary = self.executable('''import json, os, sys
assert sys.argv[1:] == ["agent", "stdio"]
assert os.environ["GROK_HOME"] == ''' + repr(str(self.directory)) + '''
for line in sys.stdin:
    request = json.loads(line)
    assert request["jsonrpc"] == "2.0"
    with open(''' + repr(str(record)) + ''', "a") as out:
        out.write(line)
    if request.get("id") == 1:
        assert request["params"]["protocolVersion"] == 1
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}), flush=True)
    elif request.get("id") == 2:
        assert request["method"] == "_x.ai/billing"
        print(json.dumps({"jsonrpc": "2.0", "id": 2,
            "result": {"config": {"creditUsagePercent": 100, "prepaidBalance": {}}}}), flush=True)
''')
        payload = quota.grok_limits(binary, 2, self.directory)
        requests = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual([r["method"] for r in requests], ["initialize", "_x.ai/billing"])
        self.assertEqual(quota.grok_billing(payload)["windows"][0]["remaining_percent"], 0)

    def test_grok_login_error_does_not_expose_server_credentials(self):
        binary = self.executable('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
        "error": {"code": -32603, "message": "authentication failed: fixture-secret",
                  "data": {"access_token": "fixture-private-token"}}}), flush=True)
''')
        with self.assertRaises(quota.QuotaError) as raised:
            quota.grok_limits(binary, 2, self.directory)
        self.assertEqual(raised.exception.status, "auth_required")
        self.assertNotIn("fixture-secret", str(raised.exception))
        self.assertNotIn("fixture-private-token", str(raised.exception))

    def test_grok_denies_client_requests_during_account_probe(self):
        binary = self.executable('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif request.get("id") == 2:
        print(json.dumps({"id": 99, "method": "fs/write_text_file", "params": {}}), flush=True)
    elif request.get("id") == 99:
        assert request["error"]["code"] == -32601
        print(json.dumps({"id": 2, "result": {"config": {"creditUsagePercent": 0}}}), flush=True)
''')
        self.assertEqual(quota.grok_limits(binary, 2, self.directory)["config"]["creditUsagePercent"], 0)

    def test_grok_stalled_native_server_is_terminated(self):
        binary = self.executable("import time\ntime.sleep(60)\n")
        with self.assertRaises(quota.QuotaError) as raised:
            quota.grok_limits(binary, .1, self.directory)
        self.assertEqual(raised.exception.status, "timeout")


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests = []
        cls.posts = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                cls.posts.append((self.path, self.headers.get("Content-Type"), body.decode()))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"access_token":"fixture-new","expires_in":3600}')

            def do_GET(self):
                cls.requests.append((self.path, self.headers.get("Authorization")))
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/credential-leak-target")
                    self.end_headers()
                    return
                status = 401 if self.path == "/unauthorized" else 429 if self.path == "/rate-limited" else 200
                self.send_response(status)
                self.end_headers()
                body = b"not json" if self.path == "/invalid" else b'{"remaining":0}'
                if self.path == "/large":
                    body = b"x" * (2 * 1024 * 1024 + 1)
                if self.path == "/slow":
                    for value in body:
                        try:
                            self.wfile.write(bytes([value]))
                            self.wfile.flush()
                            time.sleep(.02)
                        except OSError:
                            return
                else:
                    try:
                        self.wfile.write(body)
                    except OSError:
                        pass
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.url = "http://127.0.0.1:" + str(cls.server.server_port)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.environment = patch.dict(os.environ, {"NO_PROXY": "127.0.0.1", "no_proxy": "127.0.0.1"})
        cls.environment.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)
        cls.environment.stop()

    def test_http_exhausted_quota_is_read(self):
        self.assertEqual(quota.fetch_json(self.url + "/ok", 1)["remaining"], 0)

    def test_oauth_refresh_uses_form_body_and_keeps_token_out_of_url(self):
        self.posts.clear()
        result = quota.fetch_json(self.url + "/api/oauth/token", 1,
            body={"grant_type": "refresh_token", "refresh_token": "fixture+a&b=c"}, form=True)
        self.assertEqual(result["access_token"], "fixture-new")
        path, content_type, body = self.posts[0]
        self.assertEqual(path, "/api/oauth/token")
        self.assertEqual(content_type, "application/x-www-form-urlencoded")
        self.assertEqual(quota.urllib.parse.parse_qs(body)["refresh_token"], ["fixture+a&b=c"])

    def test_claude_refresh_uses_json_body(self):
        self.posts.clear()
        body = {"client_id": "fixture-client", "grant_type": "refresh_token", "refresh_token": "fixture-private"}
        quota.fetch_json(self.url + "/v1/oauth/token", 1, body=body)
        path, content_type, received = self.posts[0]
        self.assertEqual(path, "/v1/oauth/token")
        self.assertEqual(content_type, "application/json")
        self.assertEqual(json.loads(received), body)

    def test_redirect_does_not_forward_credentials(self):
        self.requests.clear()
        with self.assertRaises(quota.QuotaError):
            quota.fetch_json(self.url + "/redirect", 1, {"Authorization": "Bearer fixture-token"})
        self.assertEqual(self.requests, [("/redirect", "Bearer fixture-token")])

    def test_http_errors_are_classified_without_response_body(self):
        for endpoint, status in (("unauthorized", "auth_required"), ("rate-limited", "rate_limited")):
            with self.assertRaises(quota.QuotaError) as raised:
                quota.fetch_json(self.url + "/" + endpoint, 1)
            self.assertEqual(raised.exception.status, status)

    def test_invalid_json_is_contained(self):
        with self.assertRaises(quota.QuotaError) as raised:
            quota.fetch_json(self.url + "/invalid", 1)
        self.assertEqual(raised.exception.status, "unavailable")

    def test_large_response_is_bounded(self):
        with self.assertRaises(quota.QuotaError) as raised:
            quota.fetch_json(self.url + "/large", 1)
        self.assertIn("size limit", str(raised.exception))

    def test_slow_response_has_total_deadline(self):
        start = time.monotonic()
        with self.assertRaises(quota.QuotaError):
            quota.fetch_json(self.url + "/slow", .08)
        self.assertLess(time.monotonic() - start, .5)


if __name__ == "__main__":
    unittest.main()
