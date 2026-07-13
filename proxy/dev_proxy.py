#!/usr/bin/env python3
"""CEA local dev proxy — stdlib-only stand-in for the Cloudflare Worker.

Same contract as worker.js: holds the Anthropic API key (never in the app),
forwards to /v1/messages with an ENFORCED model + max_tokens cap, no storage.
For local development only — deploy worker.js for anything shared.

Usage:
    echo 'ANTHROPIC_API_KEY=sk-ant-...' > proxy/.dev.vars   # gitignored
    python3 proxy/dev_proxy.py                               # listens on :8787

The iOS simulator shares the Mac's localhost, so Secrets.xcconfig can point
CEA_PROXY_URL at http://127.0.0.1:8787 while this is running.
"""

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ENFORCED_MODEL = "claude-sonnet-4-6"  # per docs/CLAUDE.md agent loop
MAX_TOKENS_CAP = 1024                 # style contract: short replies
PORT = 8787


def load_api_key():
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    dev_vars = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".dev.vars")
    if not key and os.path.exists(dev_vars):
        with open(dev_vars) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ANTHROPIC_API_KEY="):
                    key = line.split("=", 1)[1].strip().strip('"')
    return key


API_KEY = load_api_key()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not API_KEY:
            return self._json(500, {"error": {"type": "api_error",
                "message": "dev proxy is missing ANTHROPIC_API_KEY (put it in proxy/.dev.vars)"}})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "Invalid JSON"}})

        # Enforce model + max_tokens regardless of what the client asked for.
        body["model"] = ENFORCED_MODEL
        try:
            requested = int(body.get("max_tokens", MAX_TOKENS_CAP))
        except (TypeError, ValueError):
            requested = MAX_TOKENS_CAP
        body["max_tokens"] = min(requested, MAX_TOKENS_CAP)
        # Streaming pass-through (v1.1 §3.5): mirror worker.js behavior.
        stream = body.get("stream") is True
        body["stream"] = stream

        request = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps(body).encode(),
            headers={
                "content-type": "application/json",
                "x-api-key": API_KEY,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as upstream:
                if stream and "text/event-stream" in (upstream.headers.get("content-type") or ""):
                    self._stream(upstream)
                else:
                    self._raw(upstream.status, upstream.read(),
                              upstream.headers.get("content-type") or "application/json")
        except urllib.error.HTTPError as e:
            self._raw(e.code, e.read())
        except urllib.error.URLError as e:
            self._json(502, {"error": {"type": "api_error", "message": "upstream unreachable: %s" % e.reason}})

    def _stream(self, upstream):
        """Relay SSE chunks as they arrive (no buffering — that's the point)."""
        self.send_response(upstream.status)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        try:
            while True:
                chunk = upstream.read(1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away; nothing to clean up (no storage)

    def _raw(self, status, payload, content_type="application/json"):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, obj):
        self._raw(status, json.dumps(obj).encode())

    def log_message(self, fmt, *args):  # no storage, minimal logging
        print("[dev-proxy] %s" % (fmt % args))


if __name__ == "__main__":
    if not API_KEY:
        print("WARNING: no ANTHROPIC_API_KEY found (env or proxy/.dev.vars) — requests will fail honestly.")
    print("CEA dev proxy on http://127.0.0.1:%d  (model=%s, max_tokens<=%d)" % (PORT, ENFORCED_MODEL, MAX_TOKENS_CAP))
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
