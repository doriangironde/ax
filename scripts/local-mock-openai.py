#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat completions server for ax e2e verification.

Serves POST /v1/chat/completions with SSE chunks: a greeting, an optional tool
call when the request includes tools and the prompt asks for a tool, usage, and
[DONE]. Also serves GET /healthz.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 43210


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/healthz":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        with open("/tmp/mock-openai.log", "a") as log:
            log.write("POST %s\n" % self.path)
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw)
        except Exception:
            request = {}
        model = request.get("model", "helper")
        messages_text = json.dumps(request.get("messages", []), ensure_ascii=False).lower()
        last_user = ""
        for message in reversed(request.get("messages", [])):
            if message.get("role") == "user" and isinstance(message.get("content"), str):
                last_user = message.get("content", "").lower()
                break
        used_tool = any(message.get("role") == "tool" for message in request.get("messages", []))
        wants_tool = (("list" in last_user or "read" in last_user) and not used_tool)
        has_tools = bool(request.get("tools"))

        def chunk(payload):
            return ("data: " + json.dumps(payload) + "\n\n").encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def send(data):
            self.wfile.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
            self.wfile.flush()

        send(chunk({
            "id": "chatcmpl-ax-e2e",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": model,
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}],
        }))
        send(chunk({
            "id": "chatcmpl-ax-e2e",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": model,
            "choices": [{"index": 0, "delta": {"content": "hello from "}, "finish_reason": None}],
        }))
        send(chunk({
            "id": "chatcmpl-ax-e2e",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": model,
            "choices": [{"index": 0, "delta": {"content": model}, "finish_reason": None}],
        }))
        if wants_tool and has_tools:
            send(chunk({
                "id": "chatcmpl-ax-e2e",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "choices": [{"index": 0, "delta": {
                    "tool_calls": [{"index": 0, "id": "call_e2e", "type": "function",
                                    "function": {"name": "list_files", "arguments": ""}}],
                }, "finish_reason": None}],
            }))
            send(chunk({
                "id": "chatcmpl-ax-e2e",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "choices": [{"index": 0, "delta": {
                    "tool_calls": [{"index": 0, "function": {"arguments": "{\"path\": \".\"}"}}],
                }, "finish_reason": None}],
            }))
            send(chunk({
                "id": "chatcmpl-ax-e2e",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15},
            }))
        else:
            send(chunk({
                "id": "chatcmpl-ax-e2e",
                "object": "chat.completion.chunk",
                "created": 0,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 7, "completion_tokens": 2, "total_tokens": 9},
            }))
        send(b"data: [DONE]\n\n")
        send(b"0\r\n\r\n")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()