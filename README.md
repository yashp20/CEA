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
proxy/    Cloudflare Worker: holds the Anthropic API key, enforces model +
          max_tokens, rate-limits. The app's only backend. No storage.
docs/     PRD + engineering guide
```

## Getting started

1. **Proxy** — deploy `proxy/` (see [proxy/README.md](proxy/README.md)) and
   set `ANTHROPIC_API_KEY` as a Worker secret. The key never ships in the app.
2. **Secrets** — copy `ios/Secrets.example.xcconfig` to `ios/Secrets.xcconfig`
   (gitignored) and fill in:
   - `CEA_PROXY_URL` — the deployed Worker URL
   - `CEA_PLACES_API_KEY` — Google Places API key (optional; without it the
     app falls back to Apple Maps search and honestly reports that venue
     accessibility data is unavailable)
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
serialization into the system prompt, and card JSON decoding.

## Non-negotiables (short form)

No order placement/booking/payment; no scraping or UI automation of third-party
platforms; never fake a capability in the UI; API key only in the proxy;
accessibility acceptance criteria are launch-blocking; capability-based copy
only. Full list in [docs/CLAUDE.md](docs/CLAUDE.md).
