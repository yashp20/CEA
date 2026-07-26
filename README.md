# CEA — Connecting with Everything, Anywhere

Accessibility-first conversational assistant for iOS. One conversation handles
the discovery and decision part of everyday errands (rides, food), personalized
to the user's accessibility profile, then hands off to the real app via deep
link. **CEA never places orders, books, or pays** — the user always confirms
the final action themselves.

Source of truth: [docs/PRD.md](docs/PRD.md) (product) and
[docs/CLAUDE.md](docs/CLAUDE.md) (engineering).

## Repo layout

```
ios/      SwiftUI app (Xcode 16+, iOS 17+, SwiftData, zero third-party deps)
proxy/    Cloudflare Worker: holds the OpenAI + Supermemory keys, translates
          the app's Anthropic-format calls to OpenAI, enforces model +
          max_tokens, rate-limits. Stores only anonymous venue accessibility
          reports (KV) and forwards preference memory to Supermemory —
          conversations are never stored.
docs/     PRD + engineering guide
```

## Getting started

1. **Proxy** — deploy `proxy/` (see [proxy/README.md](proxy/README.md)). Set
   `OPENAI_API_KEY` as a Worker secret (required). Optionally set
   `SUPERMEMORY_API_KEY` (preference-memory sync) and create the `CEA_REPORTS`
   KV namespace (`npx wrangler kv namespace create CEA_REPORTS`, then bind it in
   `wrangler.toml`) for crowdsourced accessibility reports. Keys never ship in
   the app.
2. **Secrets** — copy `ios/Secrets.example.xcconfig` to `ios/Secrets.xcconfig`
   (gitignored) and fill in:
   - `CEA_PROXY_URL` — the deployed Worker URL
   - `CEA_PLACES_API_KEY` — Google Places API key (optional; without it the
     app falls back to Apple Maps search and honestly reports that venue
     accessibility data is unavailable)
   - `CEA_ZAPIER_MCP_URL` — the user's own Zapier MCP endpoint for own-account
     actions (reminders, calendar events, notes, messages). Optional; without
     it those actions are honestly shown as unavailable.
   - Lyft partner Client ID: `DeepLinkRegistry.lyftClientID` in
     `ios/CEA/Handoff/DeepLinkRegistry.swift`
3. **Build** — open `ios/CEA.xcodeproj`, scheme `CEA`, run on iOS 17+.

## Tests

```sh
cd ios
xcodebuild -project CEA.xcodeproj -scheme CEA \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Covers the deep-link registry (every platform × param combo), profile
serialization into the system prompt, card JSON decoding, the verbosity
shaper, crowdsource report/provenance/survey-timing logic, routine step
execution, and the memory privacy split (sensitive profile fields never
leave the device).

## Non-negotiables (short form)

No order placement/booking/payment; no scraping or UI automation of third-party
platforms; never fake a capability in the UI; API key only in the proxy;
accessibility acceptance criteria are launch-blocking; capability-based copy
only. Full list in [docs/CLAUDE.md](docs/CLAUDE.md).
