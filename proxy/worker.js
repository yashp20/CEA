/**
 * CEA proxy — minimal Cloudflare Worker (CLAUDE.md architecture).
 *
 * Holds ANTHROPIC_API_KEY (never shipped in the app), forwards /v1/messages
 * with an enforced model and max_tokens cap (mechanical brevity enforcement),
 * and applies a best-effort per-client rate limit. No storage: nothing is
 * logged or persisted server-side.
 *
 * Deploy:  npx wrangler deploy
 * Secret:  npx wrangler secret put ANTHROPIC_API_KEY   // TODO(cea): set this
 */

const ENFORCED_MODEL = "claude-sonnet-4-6"; // per CLAUDE.md agent loop
const MAX_TOKENS_CAP = 1024;                // style contract: short replies
const RATE_LIMIT_PER_MINUTE = 20;

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

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ error: { type: "invalid_request_error", message: "POST only" } }, 405);
    }
    if (!env.ANTHROPIC_API_KEY) {
      return json({ error: { type: "api_error", message: "Proxy is missing ANTHROPIC_API_KEY" } }, 500);
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

    // Enforce model + max_tokens regardless of what the client asked for.
    body.model = ENFORCED_MODEL;
    body.max_tokens = Math.min(Number(body.max_tokens) || MAX_TOKENS_CAP, MAX_TOKENS_CAP);
    body.stream = false;

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(body),
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  },
};

function json(payload, status) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
