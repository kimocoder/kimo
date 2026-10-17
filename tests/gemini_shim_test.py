#!/usr/bin/env python3
"""Contract tests for lib/ollama-gemini-shim.py against a scripted Ollama upstream.

Run: tests/lib/run-hermetic.sh python3 tests/gemini_shim_test.py
"""

from __future__ import annotations

import importlib.util
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("gemini_shim", ROOT / "lib" / "ollama-gemini-shim.py")
shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shim)


class Upstream(BaseHTTPRequestHandler):
    """Fake Ollama: records /api/chat payloads, replies with the scripted response."""

    protocol_version = "HTTP/1.1"
    requests: list = []
    reply: object = None  # dict -> JSON body; list -> NDJSON stream

    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_GET(self):
        body = json.dumps({"models": [{"name": "custom:latest"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        Upstream.requests.append(json.loads(self.rfile.read(length)))
        reply = Upstream.reply
        if isinstance(reply, list):
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Connection", "close")
            self.end_headers()
            for chunk in reply:
                self.wfile.write((json.dumps(chunk) + "\n").encode())
            self.close_connection = True
        else:
            body = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class ShimTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = serve(ThreadingHTTPServer(("127.0.0.1", 0), Upstream))
        cls.shim = serve(shim.GeminiShimServer(
            ("127.0.0.1", 0), f"http://127.0.0.1:{cls.upstream.server_address[1]}", "default:latest"))
        cls.base = f"http://127.0.0.1:{cls.shim.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        for server in (cls.shim, cls.upstream):
            server.shutdown()
            server.server_close()

    def setUp(self):
        Upstream.requests = []
        Upstream.reply = {"message": {"role": "assistant", "content": "hi"}, "done": True,
                          "done_reason": "stop", "prompt_eval_count": 7, "eval_count": 3}

    def post(self, path, body, raw=None, headers=None):
        data = raw if raw is not None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method="POST",
                                     headers={"Content-Type": "application/json", **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.read().decode()

    def user(self, text="hello"):
        return {"contents": [{"role": "user", "parts": [{"text": text}]}]}

    # --- paths -------------------------------------------------------------
    def test_tagged_model_streams_with_full_name(self):
        Upstream.reply = [{"message": {"content": "a"}, "done": False},
                          {"message": {"content": ""}, "done": True, "done_reason": "stop"}]
        status, _ = self.post("/v1beta/models/custom:latest:streamGenerateContent", self.user())
        self.assertEqual(status, 200)
        self.assertEqual(Upstream.requests[0]["model"], "custom:latest")
        self.assertTrue(Upstream.requests[0]["stream"])

    def test_namespaced_url_encoded_model(self):
        self.post("/v1beta/models/kimocoder%2Fkalidroid-27b:latest:generateContent", self.user())
        self.assertEqual(Upstream.requests[0]["model"], "kimocoder/kalidroid-27b:latest")
        self.assertFalse(Upstream.requests[0]["stream"])

    def test_unknown_method_and_trailing_junk_are_404(self):
        for path in ("/v1beta/models/m:latest:latest", "/v1beta/models/m:generateContentX",
                     "/v1beta/models/m:generateContent/extra"):
            status, body = self.post(path, self.user())
            self.assertEqual(status, 404, path)
            self.assertEqual(json.loads(body)["error"]["status"], "NOT_FOUND")
        self.assertEqual(Upstream.requests, [])

    # --- streaming format --------------------------------------------------
    def test_rest_stream_is_a_json_array(self):
        Upstream.reply = [{"message": {"content": "Hel"}, "done": False},
                          {"message": {"content": "lo"}, "done": False},
                          {"message": {"content": ""}, "done": True, "done_reason": "length",
                           "prompt_eval_count": 4, "eval_count": 2}]
        status, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        self.assertEqual(status, 200)
        chunks = json.loads(body)
        self.assertIsInstance(chunks, list)
        self.assertEqual("".join(p["text"] for c in chunks for p in c["candidates"][0]["content"]["parts"]), "Hello")
        self.assertEqual(chunks[-1]["candidates"][0]["finishReason"], "MAX_TOKENS")
        self.assertEqual(chunks[-1]["usageMetadata"], {"promptTokenCount": 4, "candidatesTokenCount": 2, "totalTokenCount": 6})
        self.assertNotIn("finishReason", chunks[0]["candidates"][0])

    def test_sse_stream(self):
        Upstream.reply = [{"message": {"content": "x"}, "done": False},
                          {"message": {"content": ""}, "done": True, "done_reason": "stop"}]
        status, body = self.post("/v1beta/models/m:streamGenerateContent?alt=sse", self.user())
        self.assertEqual(status, 200)
        events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ")]
        self.assertEqual(len(events), 2)
        self.assertEqual(events[-1]["candidates"][0]["finishReason"], "STOP")

    def test_mid_stream_error_is_reported(self):
        Upstream.reply = [{"message": {"content": "partial"}, "done": False}, {"error": "model runner crashed"}]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        chunks = json.loads(body)
        self.assertIn("model runner crashed", chunks[-1]["error"]["message"])
        _, body = self.post("/v1beta/models/m:streamGenerateContent?alt=sse", self.user())
        last = json.loads([line for line in body.splitlines() if line.startswith("data: ")][-1][6:])
        self.assertIn("model runner crashed", last["error"]["message"])

    def test_truncated_stream_is_reported(self):
        Upstream.reply = [{"message": {"content": "partial"}, "done": False}]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        self.assertIn("ended before completion", json.loads(body)[-1]["error"]["message"])

    # --- tools -------------------------------------------------------------
    def test_function_declarations_and_history_are_translated(self):
        request = {
            "contents": [
                {"role": "user", "parts": [{"text": "list files"}]},
                {"role": "model", "parts": [{"functionCall": {"name": "ls", "args": {"path": "."}}}]},
                {"role": "user", "parts": [{"functionResponse": {"name": "ls", "response": {"files": ["a"]}}}]},
            ],
            "tools": [{"functionDeclarations": [{"name": "ls", "description": "List",
                                                  "parameters": {"type": "OBJECT", "properties": {
                                                      "path": {"type": "STRING", "nullable": True}},
                                                      "required": ["path"]}}]}],
        }
        status, _ = self.post("/v1beta/models/m:generateContent", request)
        self.assertEqual(status, 200)
        sent = Upstream.requests[0]
        self.assertEqual(sent["tools"], [{"type": "function", "function": {
            "name": "ls", "description": "List",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}])
        self.assertEqual(sent["messages"][1]["tool_calls"], [{"function": {"name": "ls", "arguments": {"path": "."}}}])
        self.assertEqual(sent["messages"][2], {"role": "tool", "tool_name": "ls", "content": '{"files": ["a"]}'})

    def test_upstream_tool_calls_become_function_calls(self):
        Upstream.reply = {"message": {"role": "assistant", "content": "", "tool_calls": [
            {"function": {"name": "ls", "arguments": {"path": "/tmp"}}}]}, "done": True, "done_reason": "stop"}
        _, body = self.post("/v1beta/models/m:generateContent", self.user())
        parts = json.loads(body)["candidates"][0]["content"]["parts"]
        self.assertEqual(parts, [{"functionCall": {"name": "ls", "args": {"path": "/tmp"}}}])

    def test_streamed_tool_call(self):
        Upstream.reply = [{"message": {"content": "", "tool_calls": [{"function": {"name": "ls", "arguments": "{\"p\": 1}"}}]},
                           "done": False},
                          {"message": {"content": ""}, "done": True, "done_reason": "stop"}]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        parts = json.loads(body)[0]["candidates"][0]["content"]["parts"]
        self.assertEqual(parts, [{"functionCall": {"name": "ls", "args": {"p": 1}}}])

    def test_function_calling_mode_none_drops_tools(self):
        request = {**self.user(), "tools": [{"functionDeclarations": [{"name": "ls"}]}],
                   "toolConfig": {"functionCallingConfig": {"mode": "NONE"}}}
        self.post("/v1beta/models/m:generateContent", request)
        self.assertNotIn("tools", Upstream.requests[0])

    # --- images and unsupported content -------------------------------------
    def test_inline_image_is_forwarded(self):
        request = {"contents": [{"role": "user", "parts": [
            {"text": "what is this"}, {"inlineData": {"mimeType": "image/png", "data": "iVBORw0K"}}]}]}
        status, _ = self.post("/v1beta/models/m:generateContent", request)
        self.assertEqual(status, 200)
        self.assertEqual(Upstream.requests[0]["messages"][0], {"role": "user", "content": "what is this", "images": ["iVBORw0K"]})

    def test_unsupported_content_is_rejected(self):
        for part in ({"inlineData": {"mimeType": "application/pdf", "data": "x"}},
                     {"fileData": {"mimeType": "image/png", "fileUri": "gs://b/x"}},
                     {"executableCode": {"code": "1"}}):
            status, body = self.post("/v1beta/models/m:generateContent", {"contents": [{"role": "user", "parts": [part]}]})
            self.assertEqual(status, 400, part)
            self.assertEqual(json.loads(body)["error"]["status"], "INVALID_ARGUMENT")
        self.assertEqual(Upstream.requests, [])

    # --- config, thinking, usage, countTokens --------------------------------
    def test_generation_config_mapping(self):
        request = {**self.user(), "generationConfig": {
            "temperature": 0.1, "topP": 0.9, "topK": 20, "maxOutputTokens": 64, "stopSequences": ["END"],
            "seed": 5, "responseMimeType": "application/json", "thinkingConfig": {"thinkingBudget": 0}}}
        self.post("/v1beta/models/m:generateContent", request)
        sent = Upstream.requests[0]
        self.assertEqual(sent["options"], {"temperature": 0.1, "top_p": 0.9, "top_k": 20, "num_predict": 64,
                                           "seed": 5, "stop": ["END"]})
        self.assertEqual(sent["format"], "json")
        self.assertIs(sent["think"], False)

    def test_response_schema_becomes_format(self):
        request = {**self.user(), "generationConfig": {"responseSchema": {"type": "OBJECT", "properties": {"a": {"type": "INTEGER"}}}}}
        self.post("/v1beta/models/m:generateContent", request)
        self.assertEqual(Upstream.requests[0]["format"], {"type": "object", "properties": {"a": {"type": "integer"}}})

    def test_thinking_and_usage(self):
        Upstream.reply = {"message": {"content": "42", "thinking": "let me think"}, "done": True,
                          "done_reason": "stop", "prompt_eval_count": 10, "eval_count": 5}
        _, body = self.post("/v1beta/models/m:generateContent", self.user())
        data = json.loads(body)
        self.assertEqual(data["candidates"][0]["content"]["parts"],
                         [{"text": "let me think", "thought": True}, {"text": "42"}])
        self.assertEqual(data["usageMetadata"], {"promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15})

    def test_count_tokens_does_not_call_the_model(self):
        status, body = self.post("/v1beta/models/m:latest:countTokens", self.user("x" * 40))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"totalTokens": 10})
        self.assertEqual(Upstream.requests, [])

    # --- request validation --------------------------------------------------
    def test_wrong_body_shapes_get_400(self):
        for raw in (b"[1, 2]", b"not json", json.dumps({"contents": "nope"}).encode(),
                    json.dumps({"contents": [{"parts": "nope"}]}).encode(),
                    json.dumps({**self.user(), "generationConfig": {"temperature": "hot"}}).encode()):
            status, body = self.post("/v1beta/models/m:generateContent", None, raw=raw)
            self.assertEqual(status, 400, raw)
            self.assertIn("error", json.loads(body))

    def test_upstream_http_error_is_passed_through(self):
        class Failing(Upstream):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                body = json.dumps({"error": "model 'x' not found"}).encode()
                self.send_response(404)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        failing = serve(ThreadingHTTPServer(("127.0.0.1", 0), Failing))
        other = serve(shim.GeminiShimServer(("127.0.0.1", 0), f"http://127.0.0.1:{failing.server_address[1]}", "d"))
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{other.server_address[1]}/v1beta/models/x:generateContent",
                                         data=json.dumps(self.user()).encode(), method="POST")
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req, timeout=10)
            with ctx.exception as error:
                self.assertEqual(error.code, 404)
                self.assertEqual(json.loads(error.read())["error"]["message"], "model 'x' not found")
        finally:
            for server in (other, failing):
                server.shutdown()
                server.server_close()

    def test_upstream_token_is_sent_as_bearer_only_when_configured(self):
        seen = []

        class Recording(Upstream):
            def do_POST(self):
                seen.append(self.headers.get("Authorization"))
                super().do_POST()
        upstream = serve(ThreadingHTTPServer(("127.0.0.1", 0), Recording))
        url = f"http://127.0.0.1:{upstream.server_address[1]}"
        servers = [serve(shim.GeminiShimServer(("127.0.0.1", 0), url, "d", "bridge-secret")),
                   serve(shim.GeminiShimServer(("127.0.0.1", 0), url, "d"))]
        try:
            for server in servers:
                req = urllib.request.Request(f"http://127.0.0.1:{server.server_address[1]}/v1beta/models/m:generateContent",
                                             data=json.dumps(self.user()).encode(), method="POST")
                with urllib.request.urlopen(req, timeout=10):
                    pass
            self.assertEqual(seen, ["Bearer bridge-secret", None])
        finally:
            for server in (*servers, upstream):
                server.shutdown()
                server.server_close()

    def test_non_http_upstream_is_refused(self):
        for upstream in ("file:///etc/passwd", "ftp://host/x", "127.0.0.1:11434"):
            with self.assertRaises(ValueError, msg=upstream):
                shim.GeminiShimServer(("127.0.0.1", 0), upstream, "d")

    def test_model_listing_advertises_implemented_methods(self):
        with urllib.request.urlopen(self.base + "/v1beta/models", timeout=10) as resp:
            models = json.loads(resp.read())["models"]
        self.assertEqual(models[0]["name"], "models/custom:latest")
        self.assertEqual(models[0]["supportedGenerationMethods"], ["generateContent", "streamGenerateContent", "countTokens"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
