/**
 * CEA proxy — minimal Cloudflare Worker (CLAUDE.md architecture).
 *
 * Routes:
 *   POST /            LLM proxy: holds OPENAI_API_KEY (never shipped in the
 *                     app) and TRANSLATES the app's Anthropic Messages format
 *                     to the OpenAI Chat Completions API (ChatGPT / Apple
 *                     Intelligence), enforcing model + max_tokens, streaming
 *                     translated SSE (v1.1 §3.5). The iOS agent is unchanged.
 *   POST /reports     v1.1 §3.1 crowdsourced accessibility reports: stores
 *                     one structured, timestamped, ANONYMOUS report per
 *                     venue attribute (no user IDs, no profile data, no IPs
 *                     persisted) in KV (binding CEA_REPORTS).
 *   GET  /reports     Aggregated per-venue counts with last-confirmed
 *                     timestamps — honest provenance for result cards.
 *   POST /memory      v1.1 §5 preference-memory forwarding to Supermemory
 *                     (key server-side only). NON-SENSITIVE preference
 *                     memory only; the accessibility profile never arrives
 *                     here by design (enforced in the app + tests).
 *
 * Conversations are never persisted (unchanged rule). The only stored data
 * is anonymous venue reports.
 *
 * Deploy:  npx wrangler deploy
 * Secrets: npx wrangler secret put OPENAI_API_KEY      // TODO(cea): set this
 *          npx wrangler secret put SUPERMEMORY_API_KEY // TODO(cea): §5 memory
 * KV:      npx wrangler kv namespace create CEA_REPORTS  // TODO(cea): §3.1
 *          (then add the binding to wrangler.toml)
 */

const ENFORCED_MODEL = "gpt-4o";            // ChatGPT (Apple Intelligence)
const MAX_TOKENS_CAP = 1024;                // style contract: short replies
const RATE_LIMIT_PER_MINUTE = 20;
const OPENAI_URL = "https://api.openai.com/v1/chat/completions";

// OpenAI finish_reason -> Anthropic stop_reason (the app keys its tool loop
// on stop_reason === "tool_use").
const FINISH_MAP = {
  tool_calls: "tool_use",
  function_call: "tool_use",
  stop: "end_turn",
  length: "max_tokens",
  content_filter: "end_turn",
};

// Best-effort in-memory limiter (per Worker isolate). Good enough for a
// judged demo; swap for Durable Objects/KV if this ever needs to be real.
const buckets = new Map();

function rateLimited(clientKey) {
  const now = Date.now();
  const windowStart = now - 60_000;
  const hits = (buckets.get(clientKey) || []).filter((t) => t > windowStart);
  hits.push(now);
  buckets.set(clientKey, hits);
  if (buckets.size > 10_000) buckets.clear(); // crude memory guard
  return hits.length > RATE_LIMIT_PER_MINUTE;
}

// v1.1 §3.1 — the structured report vocabulary. Anything else is rejected.
const REPORT_ATTRIBUTES = [
  "step_free_entry",
  "door_width",
  "low_noise",
  "even_lighting",
  "accessible_bathroom",
  "asl_friendly",
];
const MAX_REPORTS_PER_VENUE = 500;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/reports") {
      return handleReports(request, env, url);
    }
    if (url.pathname === "/memory") {
      return handleMemory(request, env);
    }

    if (request.method !== "POST") {
      return json({ error: { type: "invalid_request_error", message: "POST only" } }, 405);
    }
    if (!env.OPENAI_API_KEY) {
      return json({ error: { type: "api_error", message: "Proxy is missing OPENAI_API_KEY" } }, 500);
    }

    const clientKey = request.headers.get("cf-connecting-ip") || "unknown";
    if (rateLimited(clientKey)) {
      return json({ error: { type: "rate_limit_error", message: "Too many requests — try again in a minute." } }, 429);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: { type: "invalid_request_error", message: "Invalid JSON" } }, 400);
    }

    // Streaming by default (v1.1 §3.5 latency budget): voice-first users hear
    // the first sentence, not dead air.
    const stream = body.stream === true;
    const openaiBody = anthropicToOpenAIRequest(body, stream);

    const upstream = await fetch(OPENAI_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + env.OPENAI_API_KEY,
      },
      body: JSON.stringify(openaiBody),
    });

    // OpenAI error bodies are already {"error":{"message":..}} — pass through.
    if (!upstream.ok) {
      return new Response(upstream.body, {
        status: upstream.status,
        headers: { "content-type": upstream.headers.get("content-type") || "application/json" },
      });
    }

    if (stream) {
      return new Response(translateStream(upstream.body), {
        status: 200,
        headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
      });
    }
    const oa = await upstream.json();
    return json(openAIToAnthropicResponse(oa), 200);
  },
};

// MARK: Anthropic Messages <-> OpenAI Chat Completions translation
// Keeps the entire iOS agent unchanged while GPT is the model behind the proxy.

function anthropicToOpenAIRequest(body, stream) {
  const messages = [];
  if (typeof body.system === "string" && body.system.trim()) {
    messages.push({ role: "system", content: body.system });
  }
  for (const msg of body.messages || []) {
    const blocks = Array.isArray(msg.content) ? msg.content : [{ type: "text", text: String(msg.content) }];
    if (msg.role === "assistant") {
      const textParts = [];
      const toolCalls = [];
      for (const b of blocks) {
        if (b.type === "text") textParts.push(b.text || "");
        else if (b.type === "tool_use") {
          toolCalls.push({ id: b.id || "", type: "function", function: { name: b.name || "", arguments: JSON.stringify(b.input || {}) } });
        }
      }
      const content = textParts.filter(Boolean).join("\n");
      const m = { role: "assistant", content: content || null };
      if (toolCalls.length) m.tool_calls = toolCalls;
      messages.push(m);
    } else {
      const textParts = [];
      const toolResults = [];
      for (const b of blocks) {
        if (b.type === "text") textParts.push(b.text || "");
        else if (b.type === "tool_result") toolResults.push(b);
      }
      // Tool outputs must follow the assistant's tool_calls, before user text.
      for (const tr of toolResults) {
        messages.push({ role: "tool", tool_call_id: tr.tool_use_id || "", content: tr.content || "" });
      }
      const joined = textParts.filter(Boolean).join("\n");
      if (joined) messages.push({ role: "user", content: joined });
    }
  }
  const out = {
    model: ENFORCED_MODEL,
    messages,
    max_tokens: Math.min(Number(body.max_tokens) || MAX_TOKENS_CAP, MAX_TOKENS_CAP),
    stream,
  };
  if (body.tools && body.tools.length) {
    out.tools = body.tools.map((t) => ({
      type: "function",
      function: { name: t.name, description: t.description || "", parameters: t.input_schema || { type: "object", properties: {} } },
    }));
  }
  return out;
}

function openAIToAnthropicResponse(oa) {
  const choice = (oa.choices || [{}])[0];
  const msg = choice.message || {};
  const content = [];
  if (msg.content) content.push({ type: "text", text: msg.content });
  for (const tc of msg.tool_calls || []) {
    let args = {};
    try { args = JSON.parse(tc.function?.arguments || "{}"); } catch { args = {}; }
    content.push({ type: "tool_use", id: tc.id || "", name: tc.function?.name || "", input: args });
  }
  return { type: "message", role: "assistant", content, stop_reason: FINISH_MAP[choice.finish_reason] || "end_turn" };
}

// OpenAI SSE stream -> Anthropic SSE stream (same event shapes the app parses).
function translateStream(upstreamBody) {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let buffer = "";
  let nextIndex = 0;
  let textIndex = null;
  const toolMap = new Map(); // OpenAI tool index -> Anthropic block index
  const openBlocks = [];
  let finishReason = null;

  const sse = (controller, obj) => controller.enqueue(encoder.encode("data: " + JSON.stringify(obj) + "\n\n"));

  return new ReadableStream({
    async start(controller) {
      sse(controller, { type: "message_start" });
      const reader = upstreamBody.getReader();
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("data:")) continue;
            const payload = trimmed.slice(5).trim();
            if (payload === "[DONE]") continue;
            let chunk;
            try { chunk = JSON.parse(payload); } catch { continue; }
            const choice = (chunk.choices || [{}])[0];
            const delta = choice.delta || {};

            if (delta.content) {
              if (textIndex === null) {
                textIndex = nextIndex++;
                openBlocks.push(textIndex);
                sse(controller, { type: "content_block_start", index: textIndex, content_block: { type: "text", text: "" } });
              }
              sse(controller, { type: "content_block_delta", index: textIndex, delta: { type: "text_delta", text: delta.content } });
            }
            for (const tc of delta.tool_calls || []) {
              const oaiIdx = tc.index ?? 0;
              if (!toolMap.has(oaiIdx)) {
                const aIdx = nextIndex++;
                toolMap.set(oaiIdx, aIdx);
                openBlocks.push(aIdx);
                sse(controller, { type: "content_block_start", index: aIdx, content_block: { type: "tool_use", id: tc.id || "", name: tc.function?.name || "" } });
              }
              const args = tc.function?.arguments;
              if (args) sse(controller, { type: "content_block_delta", index: toolMap.get(oaiIdx), delta: { type: "input_json_delta", partial_json: args } });
            }
            if (choice.finish_reason) finishReason = choice.finish_reason;
          }
        }
        for (const idx of openBlocks) sse(controller, { type: "content_block_stop", index: idx });
        sse(controller, { type: "message_delta", delta: { stop_reason: FINISH_MAP[finishReason] || "end_turn" } });
        sse(controller, { type: "message_stop" });
      } finally {
        controller.close();
      }
    },
  });
}

// MARK: v1.1 §3.1 — crowdsourced accessibility reports (anonymous)

async function handleReports(request, env, url) {
  if (!env.CEA_REPORTS) {
    // TODO(cea): create the KV namespace and bind it in wrangler.toml.
    return json({ error: { type: "api_error", message: "Report storage isn't configured on this deployment." } }, 503);
  }

  if (request.method === "GET") {
    const venueKey = (url.searchParams.get("venue_key") || "").slice(0, 200);
    if (!venueKey) return json({ error: { type: "invalid_request_error", message: "venue_key required" } }, 400);
    const reports = (await env.CEA_REPORTS.get("reports:" + venueKey, "json")) || [];
    return json(aggregate(reports));
  }

  if (request.method === "POST") {
    const clientKey = request.headers.get("cf-connecting-ip") || "unknown";
    if (rateLimited("reports:" + clientKey)) {
      return json({ error: { type: "rate_limit_error", message: "Too many reports — try again in a minute." } }, 429);
    }
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: { type: "invalid_request_error", message: "Invalid JSON" } }, 400);
    }
    const venueKey = String(body.venue_key || "").slice(0, 200);
    const attribute = String(body.attribute || "");
    const value = body.value;
    if (!venueKey || !REPORT_ATTRIBUTES.includes(attribute) || typeof value !== "boolean") {
      return json({ error: { type: "invalid_request_error", message: "venue_key, attribute (known), boolean value required" } }, 400);
    }
    const storageKey = "reports:" + venueKey;
    const reports = (await env.CEA_REPORTS.get(storageKey, "json")) || [];
    // Anonymous by construction: attribute + value + server timestamp +
    // display metadata. No user IDs, no profile data, no IPs.
    reports.push({
      attribute,
      value,
      venue_name: String(body.venue_name || "").slice(0, 120),
      latitude: Number(body.latitude) || null,
      longitude: Number(body.longitude) || null,
      created_at: new Date().toISOString(),
    });
    await env.CEA_REPORTS.put(storageKey, JSON.stringify(reports.slice(-MAX_REPORTS_PER_VENUE)));
    return json({ ok: true, total: reports.length });
  }

  return json({ error: { type: "invalid_request_error", message: "GET or POST only" } }, 405);
}

function aggregate(reports) {
  const attributes = {};
  for (const report of reports) {
    if (!REPORT_ATTRIBUTES.includes(report.attribute)) continue;
    const entry = attributes[report.attribute] || { yes: 0, no: 0, last_at: null };
    if (report.value === true) entry.yes += 1;
    else entry.no += 1;
    if (!entry.last_at || report.created_at > entry.last_at) entry.last_at = report.created_at;
    attributes[report.attribute] = entry;
  }
  return { total: reports.length, attributes };
}

// MARK: v1.1 §5 — preference-memory forwarding (Supermemory; key stays here)

async function handleMemory(request, env) {
  if (request.method !== "POST") {
    return json({ error: { type: "invalid_request_error", message: "POST only" } }, 405);
  }
  if (!env.SUPERMEMORY_API_KEY) {
    // TODO(cea): npx wrangler secret put SUPERMEMORY_API_KEY
    return json({ configured: false }, 200);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: { type: "invalid_request_error", message: "Invalid JSON" } }, 400);
  }
  const op = String(body.op || "");
  const namespace = String(body.namespace || "").slice(0, 64);
  if (!namespace) {
    return json({ error: { type: "invalid_request_error", message: "namespace required" } }, 400);
  }
  const containerTag = "cea-" + namespace;
  const auth = { authorization: "Bearer " + env.SUPERMEMORY_API_KEY, "content-type": "application/json" };

  // Paths verified against supermemory.ai/docs API reference (2026-07-08):
  // add: POST /v3/documents {content, customId, containerTag}
  // delete one: DELETE /v3/documents/{id-or-customId} (204 on success)
  // delete all: DELETE /v3/documents/bulk {containerTags: [tag]}
  if (op === "add") {
    const key = String(body.key || "").slice(0, 100);
    const value = String(body.value || "").slice(0, 500);
    if (!key || !value) return json({ error: { type: "invalid_request_error", message: "key and value required" } }, 400);
    const upstream = await fetch("https://api.supermemory.ai/v3/documents", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ content: key + ": " + value, customId: containerTag + ":" + key, containerTag }),
    });
    return json({ configured: true, ok: upstream.ok }, upstream.ok ? 200 : 502);
  }
  if (op === "delete") {
    const target = "https://api.supermemory.ai/v3/documents/" + encodeURIComponent(containerTag + ":" + String(body.key || ""));
    const upstream = await fetch(target, { method: "DELETE", headers: auth });
    // 404 counts as done: the goal state (not stored vendor-side) holds.
    const ok = upstream.ok || upstream.status === 404;
    return json({ configured: true, ok }, ok ? 200 : 502);
  }
  if (op === "delete_all") {
    const upstream = await fetch("https://api.supermemory.ai/v3/documents/bulk", {
      method: "DELETE",
      headers: auth,
      body: JSON.stringify({ containerTags: [containerTag] }),
    });
    return json({ configured: true, ok: upstream.ok }, upstream.ok ? 200 : 502);
  }
  return json({ error: { type: "invalid_request_error", message: "op must be add, delete, or delete_all" } }, 400);
}

function json(payload, status) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
