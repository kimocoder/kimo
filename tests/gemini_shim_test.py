#!/usr/bin/env python3
"""Contract tests for lib/ollama-gemini-shim.py against the upstream wires:
a scripted Ollama /api/chat daemon, a scripted OpenAI-compatible
/chat/completions API shaped like Model Studio's compatible-mode surface,
and a scripted Responses /responses API shaped like the ChatGPT Codex route.

Run: tests/lib/run-hermetic.sh python3 tests/gemini_shim_test.py
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import tempfile
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

    def log_message(self, format, *args):  # noqa: A002  # pylint: disable=redefined-builtin
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
            for chunk in reply:  # pylint: disable=not-an-iterable
                self.wfile.write((json.dumps(chunk) + "\n").encode())
            self.close_connection = True  # pylint: disable=attribute-defined-outside-init
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


def sse(obj):
    """One OpenAI-compatible SSE event line."""
    return "data: " + json.dumps(obj)


class GeminiClientMixin:
    """Request helpers shared by the Ollama- and OpenAI-upstream suites."""

    base = ""

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


class ShimTest(GeminiClientMixin, unittest.TestCase):
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

    def test_client_key_is_required_when_configured(self):
        upstream = f"http://127.0.0.1:{self.upstream.server_address[1]}"
        keyed = serve(shim.GeminiShimServer(("127.0.0.1", 0), upstream, "d", client_key="session-key"))
        base = f"http://127.0.0.1:{keyed.server_address[1]}"

        def status(path, method="GET", headers=None):
            data = json.dumps(self.user()).encode() if method == "POST" else None
            req = urllib.request.Request(base + path, data=data, method=method, headers=headers or {})
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return resp.status
            except urllib.error.HTTPError as e:
                with e:
                    return e.code

        generate = "/v1beta/models/m:generateContent"
        try:
            self.assertEqual(status("/healthz"), 200, "health checks stay open")
            self.assertEqual(status("/v1beta/models"), 401)
            self.assertEqual(status(generate, "POST"), 401)
            self.assertEqual(status(generate, "POST", {"x-goog-api-key": "wrong"}), 401)
            self.assertEqual(Upstream.requests, [], "a refused request never reaches the upstream")
            self.assertEqual(status("/v1beta/models", headers={"x-goog-api-key": "session-key"}), 200)
            self.assertEqual(status(generate, "POST", {"x-goog-api-key": "session-key"}), 200)
            self.assertEqual(status(generate + "?key=session-key", "POST"), 200)
        finally:
            keyed.shutdown()
            keyed.server_close()

    def test_non_http_upstream_is_refused(self):
        for upstream in ("file:///etc/passwd", "ftp://host/x", "127.0.0.1:11434"):
            with self.assertRaises(ValueError, msg=upstream):
                shim.GeminiShimServer(("127.0.0.1", 0), upstream, "d")

    def test_model_listing_advertises_implemented_methods(self):
        with urllib.request.urlopen(self.base + "/v1beta/models", timeout=10) as resp:
            models = json.loads(resp.read())["models"]
        self.assertEqual(models[0]["name"], "models/custom:latest")
        self.assertEqual(models[0]["supportedGenerationMethods"], ["generateContent", "streamGenerateContent", "countTokens"])


class OpenAIUpstream(BaseHTTPRequestHandler):
    """Fake hosted OpenAI-compatible API, shaped like Model Studio compatible-mode."""

    protocol_version = "HTTP/1.1"
    requests: list = []
    paths: list = []
    auth: list = []
    status: int = 200
    reply: object = None  # dict -> JSON body; list -> SSE event lines

    def log_message(self, format, *args):  # noqa: A002  # pylint: disable=redefined-builtin
        pass

    def do_GET(self):
        OpenAIUpstream.paths.append(self.path)
        OpenAIUpstream.auth.append(self.headers.get("Authorization"))
        body = json.dumps({"object": "list", "data": [{"id": "qwen3.8-max"},
                                                      {"id": "qwen3-coder-plus"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        OpenAIUpstream.requests.append(json.loads(self.rfile.read(length)))
        OpenAIUpstream.paths.append(self.path)
        OpenAIUpstream.auth.append(self.headers.get("Authorization"))
        reply = OpenAIUpstream.reply
        if isinstance(reply, list):
            self.send_response(OpenAIUpstream.status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for event in reply:  # pylint: disable=not-an-iterable
                self.wfile.write((event + "\n\n").encode())
            self.close_connection = True  # pylint: disable=attribute-defined-outside-init
        else:
            body = json.dumps(reply).encode()
            self.send_response(OpenAIUpstream.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)


class OpenAIShimTest(GeminiClientMixin, unittest.TestCase):
    """The --upstream-kind openai path: Gemini wire onto a hosted provider."""

    @classmethod
    def setUpClass(cls):
        cls.upstream = serve(ThreadingHTTPServer(("127.0.0.1", 0), OpenAIUpstream))
        cls.origin = f"http://127.0.0.1:{cls.upstream.server_address[1]}/compatible-mode/v1"
        cls.shim = serve(shim.GeminiShimServer(("127.0.0.1", 0), cls.origin,
                                               "qwen3.8-max", upstream_kind="openai"))
        cls.base = f"http://127.0.0.1:{cls.shim.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        for server in (cls.shim, cls.upstream):
            server.shutdown()
            server.server_close()

    def setUp(self):
        OpenAIUpstream.requests = []
        OpenAIUpstream.paths = []
        OpenAIUpstream.auth = []
        OpenAIUpstream.status = 200
        OpenAIUpstream.reply = {"id": "chatcmpl-1", "model": "qwen3.8-max-0902",
                                "choices": [{"index": 0, "finish_reason": "stop",
                                             "message": {"role": "assistant", "content": "hi"}}],
                                "usage": {"prompt_tokens": 7, "completion_tokens": 3,
                                          "total_tokens": 10}}

    # --- request translation ------------------------------------------------
    def test_sampling_controls_land_at_the_top_level(self):
        request = {**self.user(), "generationConfig": {
            "temperature": 0.1, "topP": 0.9, "topK": 20, "maxOutputTokens": 64,
            "stopSequences": ["END"], "seed": 5, "presencePenalty": 0.2,
            "frequencyPenalty": 0.3}}
        status, _ = self.post("/v1beta/models/qwen3.8-max:generateContent", request)
        self.assertEqual(status, 200)
        sent = OpenAIUpstream.requests[0]
        self.assertEqual(OpenAIUpstream.paths[0], "/compatible-mode/v1/chat/completions")
        self.assertEqual(sent["model"], "qwen3.8-max")
        self.assertEqual(sent["temperature"], 0.1)
        self.assertEqual(sent["top_p"], 0.9)
        self.assertEqual(sent["max_tokens"], 64)
        self.assertEqual(sent["stop"], ["END"])
        self.assertEqual(sent["seed"], 5)
        self.assertEqual(sent["presence_penalty"], 0.2)
        self.assertEqual(sent["frequency_penalty"], 0.3)
        self.assertNotIn("options", sent, "the OpenAI wire has no options object")
        self.assertNotIn("top_k", sent, "the OpenAI wire has no top_k")
        self.assertIs(sent["stream"], False)
        self.assertNotIn("stream_options", sent)

    def test_stream_asks_for_usage(self):
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "hi"}}]}),
                                "data: [DONE]"]
        self.post("/v1beta/models/m:streamGenerateContent", self.user())
        sent = OpenAIUpstream.requests[0]
        self.assertIs(sent["stream"], True)
        self.assertEqual(sent["stream_options"], {"include_usage": True})

    def test_system_instruction_and_roles(self):
        request = {"systemInstruction": {"parts": [{"text": "be brief"}]},
                   "contents": [{"role": "user", "parts": [{"text": "hi"}]},
                                {"role": "model", "parts": [{"text": "hello"}]}]}
        self.post("/v1beta/models/m:generateContent", request)
        self.assertEqual(OpenAIUpstream.requests[0]["messages"], [
            {"role": "system", "content": "be brief"},
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "hello"}])

    def test_image_becomes_a_data_url_part(self):
        request = {"contents": [{"role": "user", "parts": [
            {"text": "what is this"}, {"inlineData": {"mimeType": "image/png", "data": "iVBORw0K"}}]}]}
        status, _ = self.post("/v1beta/models/m:generateContent", request)
        self.assertEqual(status, 200)
        self.assertEqual(OpenAIUpstream.requests[0]["messages"][0], {"role": "user", "content": [
            {"type": "text", "text": "what is this"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0K"}}]})

    def test_unsupported_content_is_still_rejected(self):
        for part in ({"inlineData": {"mimeType": "application/pdf", "data": "x"}},
                     {"fileData": {"mimeType": "image/png", "fileUri": "gs://b/x"}}):
            status, body = self.post("/v1beta/models/m:generateContent",
                                     {"contents": [{"role": "user", "parts": [part]}]})
            self.assertEqual(status, 400, part)
            self.assertEqual(json.loads(body)["error"]["status"], "INVALID_ARGUMENT")
        self.assertEqual(OpenAIUpstream.requests, [])

    def test_tool_history_and_choice_are_rendered_for_openai(self):
        request = {"contents": [
            {"role": "user", "parts": [{"text": "list files"}]},
            {"role": "model", "parts": [{"functionCall": {"name": "ls", "args": {"path": "."},
                                                          "id": "call_9"}}]},
            {"role": "user", "parts": [{"functionResponse": {"name": "ls",
                                                             "response": {"files": ["a"]}}}]},
        ], "tools": [{"functionDeclarations": [{"name": "ls", "description": "List",
                                                "parameters": {"type": "OBJECT", "properties": {
                                                    "path": {"type": "STRING"}}}}]}],
            "toolConfig": {"functionCallingConfig": {"mode": "ANY"}}}
        self.post("/v1beta/models/m:generateContent", request)
        sent = OpenAIUpstream.requests[0]
        self.assertEqual(sent["messages"][1]["tool_calls"], [{
            "id": "call_9", "type": "function",
            "function": {"name": "ls", "arguments": '{"path": "."}'}}])
        self.assertEqual(sent["messages"][2], {"role": "tool", "tool_call_id": "call_9",
                                               "content": '{"files": ["a"]}'})
        self.assertEqual(sent["tools"], [{"type": "function", "function": {
            "name": "ls", "description": "List",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}}}}])
        self.assertEqual(sent["tool_choice"], "required")

    def test_tool_result_without_an_id_is_matched_by_name(self):
        request = {"contents": [
            {"role": "model", "parts": [{"functionCall": {"name": "ls", "args": {}}}]},
            {"role": "user", "parts": [{"functionResponse": {"name": "ls",
                                                             "response": {"ok": True}}}]},
        ]}
        self.post("/v1beta/models/m:generateContent", request)
        sent = OpenAIUpstream.requests[0]
        self.assertEqual(sent["messages"][1]["tool_call_id"],
                         sent["messages"][0]["tool_calls"][0]["id"])

    def test_mode_none_drops_tools_and_choice(self):
        request = {**self.user(), "tools": [{"functionDeclarations": [{"name": "ls"}]}],
                   "toolConfig": {"functionCallingConfig": {"mode": "NONE"}}}
        self.post("/v1beta/models/m:generateContent", request)
        self.assertNotIn("tools", OpenAIUpstream.requests[0])
        self.assertNotIn("tool_choice", OpenAIUpstream.requests[0])

    def test_json_modes(self):
        self.post("/v1beta/models/m:generateContent",
                  {**self.user(), "generationConfig": {"responseMimeType": "application/json"}})
        self.assertEqual(OpenAIUpstream.requests[0]["response_format"], {"type": "json_object"})
        self.post("/v1beta/models/m:generateContent", {**self.user(), "generationConfig": {
            "responseSchema": {"type": "OBJECT", "properties": {"a": {"type": "INTEGER"}}}}})
        self.assertEqual(OpenAIUpstream.requests[1]["response_format"], {
            "type": "json_schema",
            "json_schema": {"name": "response_schema", "strict": True,
                            "schema": {"type": "object",
                                       "properties": {"a": {"type": "integer"}}}}})

    def test_thinking_is_forwarded_only_when_the_surface_allows_it(self):
        off = {"generationConfig": {"thinkingConfig": {"thinkingBudget": 0}}}
        self.post("/v1beta/models/m:generateContent", {**self.user(), **off})
        self.assertIs(OpenAIUpstream.requests[0]["enable_thinking"], False)
        on = {"generationConfig": {"thinkingConfig": {"includeThoughts": True,
                                                      "thinkingBudget": 512}}}
        self.post("/v1beta/models/m:generateContent", {**self.user(), **on})
        self.assertNotIn("enable_thinking", OpenAIUpstream.requests[1],
                         "compatible-mode refuses enable_thinking=true without streaming")
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "x"}}]}),
                                "data: [DONE]"]
        self.post("/v1beta/models/m:streamGenerateContent", {**self.user(), **on})
        sent = OpenAIUpstream.requests[2]
        self.assertIs(sent["enable_thinking"], True)
        self.assertEqual(sent["thinking_budget"], 512)

    # --- response translation -----------------------------------------------
    def test_completion_becomes_a_gemini_candidate(self):
        OpenAIUpstream.reply = {"model": "qwen3.8-max-0902",
                                "choices": [{"index": 0, "finish_reason": "stop",
                                             "message": {"role": "assistant", "content": "42",
                                                         "reasoning_content": "let me think"}}],
                                "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                                          "total_tokens": 15}}
        _, body = self.post("/v1beta/models/qwen3.8-max:generateContent", self.user())
        data = json.loads(body)
        self.assertEqual(data["candidates"][0]["content"]["parts"],
                         [{"text": "let me think", "thought": True}, {"text": "42"}])
        self.assertEqual(data["candidates"][0]["finishReason"], "STOP")
        self.assertEqual(data["usageMetadata"], {"promptTokenCount": 10,
                                                 "candidatesTokenCount": 5, "totalTokenCount": 15})
        self.assertEqual(data["modelVersion"], "qwen3.8-max",
                         "the requested id is echoed, not the upstream's snapshot name")

    def test_length_finish_reason_maps_to_max_tokens(self):
        OpenAIUpstream.reply = {"choices": [{"index": 0, "finish_reason": "length",
                                             "message": {"content": "cut"}}], "usage": {}}
        _, body = self.post("/v1beta/models/m:generateContent", self.user())
        data = json.loads(body)
        self.assertEqual(data["candidates"][0]["finishReason"], "MAX_TOKENS")
        self.assertEqual(data["usageMetadata"], {"promptTokenCount": 0,
                                                 "candidatesTokenCount": 0, "totalTokenCount": 0})

    def test_upstream_tool_call_becomes_a_function_call(self):
        OpenAIUpstream.reply = {"choices": [{"index": 0, "finish_reason": "tool_calls",
                                             "message": {"content": "", "tool_calls": [
                                                 {"id": "call_1", "type": "function",
                                                  "function": {"name": "ls",
                                                               "arguments": '{"path": "/tmp"}'}}]}}],
                                "usage": {}}
        _, body = self.post("/v1beta/models/m:generateContent", self.user())
        candidate_ = json.loads(body)["candidates"][0]
        self.assertEqual(candidate_["content"]["parts"],
                         [{"functionCall": {"name": "ls", "args": {"path": "/tmp"}, "id": "call_1"}}])
        self.assertEqual(candidate_["finishReason"], "STOP")

    def test_streamed_text_is_relayed_piecewise(self):
        OpenAIUpstream.reply = [
            sse({"choices": [{"index": 0, "delta": {"content": "Hel"}}]}),
            sse({"choices": [{"index": 0, "delta": {"content": "lo"}}]}),
            sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6}}),
            "data: [DONE]",
        ]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        chunks = json.loads(body)
        self.assertEqual("".join(p["text"] for c in chunks
                                 for p in c["candidates"][0]["content"]["parts"]), "Hello")
        self.assertEqual(chunks[-1]["candidates"][0]["finishReason"], "STOP")
        self.assertEqual(chunks[-1]["usageMetadata"], {"promptTokenCount": 4,
                                                       "candidatesTokenCount": 2,
                                                       "totalTokenCount": 6})

    def test_sse_framing_is_honoured(self):
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "x"}}]}),
                                sse({"choices": [{"index": 0, "delta": {},
                                                  "finish_reason": "stop"}]}),
                                "data: [DONE]"]
        _, body = self.post("/v1beta/models/m:streamGenerateContent?alt=sse", self.user())
        events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ")]
        # A chunk carrying only finish_reason yields no candidate of its own;
        # it closes the terminal one.
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["candidates"][0]["content"]["parts"], [{"text": "x"}])
        self.assertNotIn("finishReason", events[0]["candidates"][0])
        self.assertEqual(events[-1]["candidates"][0]["finishReason"], "STOP")

    def test_streamed_tool_call_fragments_are_reassembled(self):
        OpenAIUpstream.reply = [
            sse({"choices": [{"index": 0, "delta": {"reasoning_content": "hmm"}}]}),
            sse({"choices": [{"index": 0, "delta": {"tool_calls": [
                {"index": 0, "id": "call_1", "type": "function",
                 "function": {"name": "ls", "arguments": '{"pa'}}]}}]}),
            sse({"choices": [{"index": 0, "delta": {"tool_calls": [
                {"index": 0, "function": {"arguments": 'th": "/tmp"}'}}]}}]}),
            sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                 "usage": {"prompt_tokens": 4, "completion_tokens": 6, "total_tokens": 10}}),
            "data: [DONE]",
        ]
        _, body = self.post("/v1beta/models/m:streamGenerateContent?alt=sse", self.user())
        events = [json.loads(line[6:]) for line in body.splitlines() if line.startswith("data: ")]
        self.assertEqual(events[0]["candidates"][0]["content"]["parts"],
                         [{"text": "hmm", "thought": True}])
        self.assertNotIn("finishReason", events[0]["candidates"][0])
        final = events[-1]["candidates"][0]
        self.assertEqual(final["content"]["parts"], [{"functionCall": {
            "name": "ls", "args": {"path": "/tmp"}, "id": "call_1"}}])
        self.assertEqual(final["finishReason"], "STOP")
        self.assertEqual(events[-1]["usageMetadata"], {"promptTokenCount": 4,
                                                       "candidatesTokenCount": 6,
                                                       "totalTokenCount": 10})

    def test_done_without_a_finish_reason_still_terminates(self):
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "ok"}}]}),
                                "data: [DONE]"]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        chunks = json.loads(body)
        self.assertEqual(chunks[-1]["candidates"][0]["finishReason"], "STOP")
        self.assertNotIn("error", chunks[-1])

    def test_truncated_stream_is_reported(self):
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "part"}}]})]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        self.assertIn("ended before completion", json.loads(body)[-1]["error"]["message"])

    def test_mid_stream_error_is_reported(self):
        OpenAIUpstream.reply = [sse({"choices": [{"index": 0, "delta": {"content": "part"}}]}),
                                sse({"error": {"message": "upstream broke"}})]
        _, body = self.post("/v1beta/models/m:streamGenerateContent", self.user())
        self.assertIn("upstream broke", json.loads(body)[-1]["error"]["message"])

    # --- catalogue and credentials -------------------------------------------
    def test_model_listing_reads_the_openai_catalogue(self):
        with urllib.request.urlopen(self.base + "/v1beta/models", timeout=10) as resp:
            models = json.loads(resp.read())["models"]
        self.assertEqual(OpenAIUpstream.paths[0], "/compatible-mode/v1/models")
        self.assertEqual([m["name"] for m in models],
                         ["models/qwen3.8-max", "models/qwen3-coder-plus"])

    def test_provider_key_reaches_the_upstream_as_bearer(self):
        keyed = serve(shim.GeminiShimServer(("127.0.0.1", 0), self.origin, "qwen3.8-max",
                                            "sk-sp-fixture", upstream_kind="openai"))
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{keyed.server_address[1]}/v1beta/models/m:generateContent",
                data=json.dumps(self.user()).encode(), method="POST")
            with urllib.request.urlopen(req, timeout=10):
                pass
            self.assertEqual(OpenAIUpstream.auth[-1], "Bearer sk-sp-fixture")
        finally:
            keyed.shutdown()
            keyed.server_close()

    def test_upstream_error_message_is_extracted(self):
        OpenAIUpstream.status = 400
        OpenAIUpstream.reply = {"error": {"message": "model 'qwen9' not found",
                                          "type": "invalid_request_error",
                                          "code": "Model.NotFound"}}
        status, body = self.post("/v1beta/models/qwen9:generateContent", self.user())
        self.assertEqual(status, 400)
        error = json.loads(body)["error"]
        self.assertEqual(error["message"], "model 'qwen9' not found")
        self.assertEqual(error["status"], "INVALID_ARGUMENT")

    def test_count_tokens_never_reaches_the_upstream(self):
        status, body = self.post("/v1beta/models/m:countTokens", self.user("x" * 40))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"totalTokens": 10})
        self.assertEqual(OpenAIUpstream.requests, [])

    def test_unknown_upstream_kind_is_refused(self):
        with self.assertRaises(ValueError):
            shim.GeminiShimServer(("127.0.0.1", 0), "http://127.0.0.1:1", "d",
                                  upstream_kind="gemini")


def _jwt(account: str) -> str:
    def part(obj: dict) -> str:
        raw = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
        return raw
    body = {"https://api.openai.com/auth": {"chatgpt_account_id": account}}
    return part({"alg": "none"}) + "." + part(body) + ".sig"


class ResponsesUpstream(BaseHTTPRequestHandler):
    """Fake Responses server. SSE when the body asks to stream, else one JSON object."""

    protocol_version = "HTTP/1.1"
    requests: list = []
    paths: list = []
    headers: list = []

    def log_message(self, format, *args):  # noqa: A002  # pylint: disable=redefined-builtin
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length))
        ResponsesUpstream.requests.append(payload)
        ResponsesUpstream.paths.append(self.path)
        ResponsesUpstream.headers.append({
            "authorization": self.headers.get("Authorization"),
            "beta": self.headers.get("OpenAI-Beta"),
            "originator": self.headers.get("originator"),
            "version": self.headers.get("version"),
            "session_id": self.headers.get("session_id"),
            "session-id": self.headers.get("session-id"),
            "user_agent": self.headers.get("User-Agent"),
            "hint": self.headers.get("x-codex-routing-hint"),
            "account": self.headers.get("Chatgpt-Account-Id"),
            "lite": self.headers.get("x-openai-internal-codex-responses-lite"),
            "residency": self.headers.get("x-openai-internal-codex-residency"),
            "accept": self.headers.get("Accept"),
        })
        if payload.get("stream") is False:
            body = json.dumps({
                "status": "completed",
                "output": [{"type": "message", "role": "assistant",
                            "content": [{"type": "output_text", "text": "PONG"}]}],
                "usage": {"input_tokens": 2, "output_tokens": 1},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        events = "\n\n".join([
            sse({"type": "response.reasoning_summary_text.delta", "delta": "think"}),
            sse({"type": "response.output_text.delta", "delta": "PONG"}),
            sse({"type": "response.output_item.added", "output_index": 1,
                 "item": {"type": "function_call", "call_id": "call_9", "name": "Bash", "arguments": ""}}),
            sse({"type": "response.function_call_arguments.delta", "output_index": 1,
                 "delta": "{\"command\":\"ls\"}"}),
            sse({"type": "response.completed",
                 "response": {"status": "completed", "usage": {"input_tokens": 3, "output_tokens": 4}}}),
        ]) + "\n\n"
        raw = events.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class ResponsesShimTest(GeminiClientMixin, unittest.TestCase):
    """Responses kind, with and without the ChatGPT Codex header contract."""

    @classmethod
    def setUpClass(cls):
        cls.upstream = serve(ThreadingHTTPServer(("127.0.0.1", 0), ResponsesUpstream))
        origin = f"http://127.0.0.1:{cls.upstream.server_address[1]}"
        cls.home = tempfile.TemporaryDirectory()
        cache = {
            "client_version": "9.9.9-test",
            "models": [
                {"slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list",
                 "default_reasoning_level": "medium", "use_responses_lite": False},
                {"slug": "gpt-6.1-terra", "display_name": "GPT-6.1 Terra", "visibility": "list",
                 "default_reasoning_level": "low", "use_responses_lite": True},
                {"slug": "hidden", "visibility": "hide", "display_name": "Hidden"},
            ],
        }
        os.makedirs(cls.home.name, exist_ok=True)
        with open(os.path.join(cls.home.name, "models_cache.json"), "w", encoding="utf-8") as handle:
            json.dump(cache, handle)
        cls._prev_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = cls.home.name
        cls.token = _jwt("acc-agy")
        cls.codex = serve(shim.GeminiShimServer(
            ("127.0.0.1", 0), origin, "gpt-6.1-sol", upstream_token=cls.token,
            upstream_kind="responses", codex=True))
        cls.plain = serve(shim.GeminiShimServer(
            ("127.0.0.1", 0), origin, "gpt-6.1-sol", upstream_kind="responses"))
        cls.base = f"http://127.0.0.1:{cls.codex.server_address[1]}"
        cls.plain_base = f"http://127.0.0.1:{cls.plain.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        for server in (cls.codex, cls.plain, cls.upstream):
            server.shutdown()
            server.server_close()
        if cls._prev_home is None:
            os.environ.pop("CODEX_HOME", None)
        else:
            os.environ["CODEX_HOME"] = cls._prev_home
        cls.home.cleanup()

    def setUp(self):
        ResponsesUpstream.requests = []
        ResponsesUpstream.paths = []
        ResponsesUpstream.headers = []

    def test_a_non_jwt_token_omits_the_account_header(self):
        headers = shim.codex_headers("codex-oauth-fixture", "gpt-6.1-sol",
                                     version="0.167.0", session_id="abc", lite=False)
        self.assertNotIn("Chatgpt-Account-Id", headers)
        self.assertNotIn("x-openai-internal-codex-residency", headers)
        self.assertEqual(headers["OpenAI-Beta"], "responses=experimental")
        self.assertEqual(headers["originator"], "codex_cli_rs")
        self.assertNotIn("responses_websockets", headers["OpenAI-Beta"])

    def test_codex_turn_is_a_streaming_responses_post(self):
        request = {
            "systemInstruction": {"parts": [{"text": "sys"}]},
            "contents": [
                {"role": "user", "parts": [{"text": "hi"},
                                           {"inlineData": {"mimeType": "image/png", "data": "iVBORw0K"}}]},
                {"role": "model", "parts": [
                    {"text": "ok"},
                    {"functionCall": {"name": "Bash", "id": "call_1", "args": {"command": "ls"}}},
                ]},
                {"role": "user", "parts": [
                    {"functionResponse": {"name": "Bash", "id": "call_1", "response": {"output": "file"}}},
                ]},
            ],
            "tools": [{"functionDeclarations": [{
                "name": "Bash", "description": "run",
                "parameters": {"type": "OBJECT", "properties": {"command": {"type": "STRING"}}},
            }]}],
            "toolConfig": {"functionCallingConfig": {"mode": "ANY", "allowedFunctionNames": ["Bash"]}},
            "generationConfig": {"maxOutputTokens": 16, "temperature": 0.2, "topK": 20},
        }
        status, body = self.post("/v1beta/models/gpt-6.1-sol:generateContent", request)
        self.assertEqual(status, 200, body)
        sent = ResponsesUpstream.requests[0]
        headers = ResponsesUpstream.headers[0]
        self.assertTrue(ResponsesUpstream.paths[0].endswith("/responses"), ResponsesUpstream.paths[0])
        self.assertEqual(sent["model"], "gpt-6.1-sol")
        self.assertIs(sent["stream"], True)
        self.assertIs(sent["store"], False)
        self.assertEqual(sent["instructions"], "sys")
        self.assertIn("reasoning.encrypted_content", sent["include"])
        self.assertEqual(sent["reasoning"], {"effort": "medium", "summary": "auto"})
        self.assertNotIn("parallel_tool_calls", sent)
        self.assertEqual(sent["max_output_tokens"], 16)
        self.assertEqual(sent["temperature"], 0.2)
        self.assertNotIn("top_k", sent)
        self.assertEqual(sent["input"][0]["content"][0], {"type": "input_text", "text": "hi"})
        self.assertEqual(sent["input"][0]["content"][1]["type"], "input_image")
        self.assertEqual(sent["input"][1]["content"], [{"type": "output_text", "text": "ok"}])
        self.assertEqual(sent["input"][2], {
            "type": "function_call", "call_id": "call_1", "name": "Bash",
            "arguments": '{"command": "ls"}'})
        self.assertEqual(sent["input"][3]["type"], "function_call_output")
        self.assertEqual(sent["input"][3]["call_id"], "call_1")
        self.assertEqual(sent["tools"], [{
            "type": "function", "name": "Bash", "description": "run",
            "parameters": {"type": "object", "properties": {"command": {"type": "string"}}},
        }])
        self.assertEqual(sent["tool_choice"], {"type": "function", "name": "Bash"})
        self.assertEqual(headers["authorization"], f"Bearer {self.token}")
        self.assertEqual(headers["beta"], "responses=experimental")
        self.assertEqual(headers["originator"], "codex_cli_rs")
        self.assertEqual(headers["version"], "9.9.9-test")
        self.assertEqual(headers["user_agent"], "codex_cli_rs/9.9.9-test")
        self.assertEqual(headers["hint"], "model=gpt-6.1-sol")
        self.assertEqual(headers["account"], "acc-agy")
        self.assertTrue(headers["session_id"])
        self.assertEqual(headers["session_id"], headers["session-id"])
        self.assertEqual(headers["accept"], "text/event-stream")
        self.assertIsNone(headers["lite"])
        self.assertIsNone(headers["residency"])
        parsed = json.loads(body)
        parts = parsed["candidates"][0]["content"]["parts"]
        self.assertEqual(parts[0], {"text": "think", "thought": True})
        self.assertEqual(parts[1], {"text": "PONG"})
        self.assertEqual(parts[2]["functionCall"]["name"], "Bash")
        self.assertEqual(parts[2]["functionCall"]["args"], {"command": "ls"})
        self.assertEqual(parsed["modelVersion"], "gpt-6.1-sol")
        self.assertEqual(parsed["usageMetadata"]["promptTokenCount"], 3)
        self.assertEqual(parsed["usageMetadata"]["candidatesTokenCount"], 4)

    def test_display_name_resolves_to_the_catalog_slug(self):
        status, body = self.post("/v1beta/models/GPT-6.1-Sol:generateContent", self.user())
        self.assertEqual(status, 200, body)
        self.assertEqual(ResponsesUpstream.requests[0]["model"], "gpt-6.1-sol")
        self.assertEqual(ResponsesUpstream.headers[0]["hint"], "model=gpt-6.1-sol")
        self.assertEqual(json.loads(body)["modelVersion"], "GPT-6.1-Sol")

    def test_lite_models_get_the_lite_contract_only(self):
        status, _ = self.post("/v1beta/models/gpt-6.1-terra:generateContent", self.user())
        self.assertEqual(status, 200)
        sent = ResponsesUpstream.requests[0]
        headers = ResponsesUpstream.headers[0]
        self.assertEqual(sent["model"], "gpt-6.1-terra")
        self.assertEqual(sent["reasoning"]["effort"], "low")
        self.assertEqual(sent["reasoning"]["context"], "all_turns")
        self.assertIs(sent["parallel_tool_calls"], False)
        self.assertEqual(sent["instructions"], "You are a coding assistant.")
        self.assertEqual(headers["lite"], "true")
        self.assertEqual(headers["hint"], "model=gpt-6.1-terra")
        self.assertIsNone(headers["residency"])

    def test_model_list_is_the_catalog_without_a_network_call(self):
        with urllib.request.urlopen(self.base + "/v1beta/models", timeout=5) as resp:
            names = [item["name"] for item in json.loads(resp.read())["models"]]
        self.assertIn("models/gpt-6.1-sol", names)
        self.assertIn("models/gpt-6.1-terra", names)
        self.assertNotIn("models/hidden", names)
        self.assertEqual(ResponsesUpstream.requests, [])

    def test_plain_responses_does_not_send_codex_headers(self):
        saved = self.base
        self.base = self.plain_base
        try:
            status, body = self.post("/v1beta/models/gpt-6.1-sol:generateContent", self.user("hi"))
        finally:
            self.base = saved
        self.assertEqual(status, 200, body)
        sent = ResponsesUpstream.requests[0]
        headers = ResponsesUpstream.headers[0]
        self.assertIs(sent["stream"], False)
        self.assertIs(sent["store"], False)
        self.assertNotIn("include", sent)
        self.assertNotIn("instructions", sent)
        self.assertEqual(sent["input"][0]["content"][0]["text"], "hi")
        self.assertIsNone(headers["originator"])
        self.assertIsNone(headers["beta"])
        self.assertIsNone(headers["account"])
        self.assertIsNone(headers["lite"])
        self.assertEqual(headers["user_agent"], "kimo-gemini-shim")
        self.assertIsNone(headers["authorization"])
        self.assertEqual(json.loads(body)["candidates"][0]["content"]["parts"], [{"text": "PONG"}])

    def test_stream_relays_text(self):
        status, body = self.post("/v1beta/models/gpt-6.1-sol:streamGenerateContent?alt=sse", self.user())
        self.assertEqual(status, 200, body)
        self.assertIn("PONG", body)
        self.assertIn("Bash", body)
        self.assertIs(ResponsesUpstream.requests[0]["stream"], True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
