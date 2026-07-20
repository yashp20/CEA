#!/usr/bin/env python3
"""CEA local dev proxy — stdlib-only stand-in for the Cloudflare Worker.

Holds the OpenAI API key (never in the app) and TRANSLATES between the app's
Anthropic Messages format and the OpenAI Chat Completions API. This keeps the
entire iOS agent (request builder, tool loop, streaming parser) unchanged while
the model behind it is GPT — aligned with Apple Intelligence's ChatGPT
integration. Enforces model + max_tokens. No storage. Local dev only.

Usage:
    echo 'OPENAI_API_KEY=sk-...' > proxy/.dev.vars   # gitignored
    python3 proxy/dev_proxy.py                        # listens on :8787

The iOS simulator shares the Mac's localhost, so Secrets.xcconfig can point
CEA_PROXY_URL at http://127.0.0.1:8787 while this is running.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ENFORCED_MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o")  # ChatGPT (Apple Intelligence)
MAX_TOKENS_CAP = 1024                                       # style contract: short replies
PORT = 8787
OPENAI_URL = "https://api.openai.com/v1/chat/completions"

# OpenAI finish_reason -> Anthropic stop_reason (the app keys its tool loop on
# stop_reason == "tool_use").
FINISH_MAP = {
    "tool_calls": "tool_use",
    "function_call": "tool_use",
    "stop": "end_turn",
    "length": "max_tokens",
    "content_filter": "end_turn",
}


def load_secret(name):
    """Load a secret from the environment or proxy/.dev.vars (gitignored)."""
    value = os.environ.get(name, "")
    dev_vars = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".dev.vars")
    if not value and os.path.exists(dev_vars):
        with open(dev_vars) as f:
            for line in f:
                line = line.strip()
                if line.startswith(name + "="):
                    value = line.split("=", 1)[1].strip().strip('"')
    return value


API_KEY = load_secret("OPENAI_API_KEY")
# v1.1 §5 — Supermemory holds NON-SENSITIVE preference memory only (cuisines,
# frequent places). The accessibility profile never reaches it (enforced in the
# app: MemoryPrivacyFilter + MemoryPrivacyTests). Optional: without this key the
# /memory route reports {"configured": false} and the app keeps its local ledger.
SUPERMEMORY_API_KEY = load_secret("SUPERMEMORY_API_KEY")


# ---- Anthropic Messages request -> OpenAI Chat Completions request ----------

def anthropic_to_openai_request(body, stream):
    messages = []
    system = body.get("system")
    if isinstance(system, str) and system.strip():
        messages.append({"role": "system", "content": system})

    for msg in body.get("messages", []):
        role = msg.get("role")
        blocks = msg.get("content", [])
        if not isinstance(blocks, list):
            blocks = [{"type": "text", "text": str(blocks)}]

        if role == "assistant":
            text_parts, tool_calls = [], []
            for b in blocks:
                if b.get("type") == "text":
                    text_parts.append(b.get("text", ""))
                elif b.get("type") == "tool_use":
                    tool_calls.append({
                        "id": b.get("id", ""),
                        "type": "function",
                        "function": {
                            "name": b.get("name", ""),
                            "arguments": json.dumps(b.get("input", {})),
                        },
                    })
            content = "\n".join(p for p in text_parts if p)
            m = {"role": "assistant", "content": content if content else None}
            if tool_calls:
                m["tool_calls"] = tool_calls
            messages.append(m)
        else:  # user turn: may carry text and/or tool_result blocks
            text_parts, tool_results = [], []
            for b in blocks:
                if b.get("type") == "text":
                    text_parts.append(b.get("text", ""))
                elif b.get("type") == "tool_result":
                    tool_results.append(b)
            # OpenAI models tool outputs as 'tool' role messages that must
            # follow the assistant's tool_calls — emit them before user text.
            for tr in tool_results:
                messages.append({
                    "role": "tool",
                    "tool_call_id": tr.get("tool_use_id", ""),
                    "content": tr.get("content", "") or "",
                })
            joined = "\n".join(p for p in text_parts if p)
            if joined:
                messages.append({"role": "user", "content": joined})

    try:
        requested = int(body.get("max_tokens", MAX_TOKENS_CAP))
    except (TypeError, ValueError):
        requested = MAX_TOKENS_CAP

    out = {
        "model": ENFORCED_MODEL,
        "messages": messages,
        "max_tokens": min(requested, MAX_TOKENS_CAP),
        "stream": stream,
    }
    tools = body.get("tools")
    if tools:
        out["tools"] = [{
            "type": "function",
            "function": {
                "name": t.get("name"),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {"type": "object", "properties": {}}),
            },
        } for t in tools]
    return out


# ---- OpenAI non-streaming response -> Anthropic Messages response -----------

def openai_to_anthropic_response(oa):
    choice = (oa.get("choices") or [{}])[0]
    msg = choice.get("message", {}) or {}
    content = []
    if msg.get("content"):
        content.append({"type": "text", "text": msg["content"]})
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function", {})
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        content.append({
            "type": "tool_use",
            "id": tc.get("id", ""),
            "name": fn.get("name", ""),
            "input": args,
        })
    return {
        "type": "message",
        "role": "assistant",
        "content": content,
        "stop_reason": FINISH_MAP.get(choice.get("finish_reason"), "end_turn"),
    }


# ---- Streaming: OpenAI chunk dicts -> Anthropic SSE event dicts -------------
# Pure generator (no I/O) so it can be unit-tested offline. Feed it decoded
# OpenAI `chat.completion.chunk` objects; it yields Anthropic stream events.

def translate_stream(chunks):
    next_index = 0
    text_index = None       # Anthropic block index of the text block
    tool_map = {}           # OpenAI tool_call index -> Anthropic block index
    open_blocks = []        # Anthropic indices still open (stop at end)
    finish_reason = None

    yield {"type": "message_start"}
    for chunk in chunks:
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}

        text = delta.get("content")
        if text:
            if text_index is None:
                text_index = next_index
                next_index += 1
                open_blocks.append(text_index)
                yield {"type": "content_block_start", "index": text_index,
                       "content_block": {"type": "text", "text": ""}}
            yield {"type": "content_block_delta", "index": text_index,
                   "delta": {"type": "text_delta", "text": text}}

        for tc in delta.get("tool_calls") or []:
            oai_idx = tc.get("index", 0)
            if oai_idx not in tool_map:
                a_idx = next_index
                next_index += 1
                tool_map[oai_idx] = a_idx
                open_blocks.append(a_idx)
                fn = tc.get("function", {}) or {}
                yield {"type": "content_block_start", "index": a_idx,
                       "content_block": {"type": "tool_use", "id": tc.get("id", ""),
                                         "name": fn.get("name", "")}}
            a_idx = tool_map[oai_idx]
            args = (tc.get("function", {}) or {}).get("arguments")
            if args:
                yield {"type": "content_block_delta", "index": a_idx,
                       "delta": {"type": "input_json_delta", "partial_json": args}}

        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]

    for idx in open_blocks:
        yield {"type": "content_block_stop", "index": idx}
    yield {"type": "message_delta", "delta": {"stop_reason": FINISH_MAP.get(finish_reason, "end_turn")}}
    yield {"type": "message_stop"}


def _iter_openai_chunks(upstream):
    """Yield decoded OpenAI chunk dicts from an SSE byte stream."""
    for raw in upstream:
        line = raw.decode("utf-8", "ignore").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            return
        try:
            yield json.loads(payload)
        except json.JSONDecodeError:
            continue


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # /memory: preference-memory sync (Supermemory). Mirrors worker.js.
        if self.path.rstrip("/").endswith("/memory"):
            return self._handle_memory()

        if not API_KEY:
            return self._json(500, {"error": {"type": "api_error",
                "message": "dev proxy is missing OPENAI_API_KEY (put it in proxy/.dev.vars)"}})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "Invalid JSON"}})

        stream = body.get("stream") is True
        openai_body = anthropic_to_openai_request(body, stream)

        request = urllib.request.Request(
            OPENAI_URL,
            data=json.dumps(openai_body).encode(),
            headers={
                "content-type": "application/json",
                "authorization": "Bearer %s" % API_KEY,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as upstream:
                ctype = upstream.headers.get("content-type") or ""
                if stream and "text/event-stream" in ctype:
                    self._stream_translate(upstream)
                else:
                    oa = json.loads(upstream.read())
                    self._json(200, openai_to_anthropic_response(oa))
        except urllib.error.HTTPError as e:
            # OpenAI error bodies are {"error":{"message":..}} — already the
            # shape the app's error decoder expects, so pass through.
            self._raw(e.code, e.read())
        except urllib.error.URLError as e:
            self._json(502, {"error": {"type": "api_error", "message": "upstream unreachable: %s" % e.reason}})

    # ---- Streaming: OpenAI SSE deltas -> Anthropic SSE events ----

    def _stream_translate(self, upstream):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        try:
            for event in translate_stream(_iter_openai_chunks(upstream)):
                self._sse(event)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away; nothing to clean up (no storage)

    def _sse(self, obj):
        self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())
        self.wfile.flush()

    # ---- /memory: preference-memory sync to Supermemory (v1.1 §5) ----
    # NON-SENSITIVE preference memory only; the accessibility profile never
    # arrives here (enforced app-side). Mirrors worker.js handleMemory.

    def _handle_memory(self):
        if not SUPERMEMORY_API_KEY:
            # Honest "not configured" — the app keeps its local ledger.
            return self._json(200, {"configured": False})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "Invalid JSON"}})

        op = str(body.get("op", ""))
        namespace = str(body.get("namespace", ""))[:64]
        if not namespace:
            return self._json(400, {"error": {"type": "invalid_request_error", "message": "namespace required"}})
        container_tag = "cea-" + namespace
        auth = {"authorization": "Bearer " + SUPERMEMORY_API_KEY, "content-type": "application/json"}

        try:
            if op == "add":
                key = str(body.get("key", ""))[:100]
                value = str(body.get("value", ""))[:500]
                if not key or not value:
                    return self._json(400, {"error": {"type": "invalid_request_error", "message": "key and value required"}})
                ok = self._supermemory("POST", "https://api.supermemory.ai/v3/documents", auth, {
                    "content": key + ": " + value,
                    "customId": container_tag + ":" + key,
                    "containerTag": container_tag,
                })
                return self._json(200 if ok else 502, {"configured": True, "ok": ok})
            if op == "delete":
                target = "https://api.supermemory.ai/v3/documents/" + \
                    urllib.parse.quote(container_tag + ":" + str(body.get("key", "")), safe="")
                ok = self._supermemory("DELETE", target, auth, None, ok_statuses=(200, 204, 404))
                return self._json(200 if ok else 502, {"configured": True, "ok": ok})
            if op == "delete_all":
                ok = self._supermemory("DELETE", "https://api.supermemory.ai/v3/documents/bulk", auth,
                                       {"containerTags": [container_tag]})
                return self._json(200 if ok else 502, {"configured": True, "ok": ok})
        except urllib.error.URLError as e:
            return self._json(502, {"error": {"type": "api_error", "message": "supermemory unreachable: %s" % e.reason}})
        return self._json(400, {"error": {"type": "invalid_request_error", "message": "op must be add, delete, or delete_all"}})

    def _supermemory(self, method, url, headers, body, ok_statuses=(200, 201, 204)):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as resp:
                return resp.status in ok_statuses
        except urllib.error.HTTPError as e:
            return e.code in ok_statuses

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
        print("WARNING: no OPENAI_API_KEY found (env or proxy/.dev.vars) — requests will fail honestly.")
    HOST = os.environ.get("CEA_PROXY_HOST", "0.0.0.0")
    print("CEA dev proxy on http://%s:%d  (model=%s, max_tokens<=%d)" % (HOST, PORT, ENFORCED_MODEL, MAX_TOKENS_CAP))
    HTTPServer((HOST, PORT), Handler).serve_forever()
