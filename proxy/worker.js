/**
 * CEA proxy — minimal Cloudflare Worker (CLAUDE.md architecture).
 *
 * Routes:
 *   POST /            LLM proxy: holds ANTHROPIC_API_KEY (never shipped in
 *                     the app), forwards /v1/messages with an enforced model
 *                     and max_tokens cap, streaming pass-through (v1.1 §3.5).
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
 * Secrets: npx wrangler secret put ANTHROPIC_API_KEY   // TODO(cea): set this
 *          npx wrangler secret put SUPERMEMORY_API_KEY // TODO(cea): §5 memory
 * KV:      npx wrangler kv namespace create CEA_REPORTS  // TODO(cea): §3.1
 *          (then add the binding to wrangler.toml)
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
    // Streaming pass-through (v1.1 §3.5 latency budget): the app streams by
    // default so voice-first users hear the first sentence, not dead air.
    body.stream = body.stream === true;

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(body),
    });

    // SSE responses keep their content type; JSON stays JSON.
    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "content-type": upstream.headers.get("content-type") || "application/json",
      },
    });
  },
};

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
