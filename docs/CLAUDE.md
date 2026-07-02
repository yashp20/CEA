# CLAUDE.md — CEA (Connecting with Everything, Everywhere)

Claude Code: read this fully before making changes. PRD.md is the product source of truth; this file is the engineering source of truth. If a request conflicts with the Non-negotiables below, flag it instead of implementing it.

## What this project is

Native iOS (Swift/SwiftUI) accessibility-first AI assistant for an iOS app creation competition (theme: Accessibility). A conversational agent handles discovery + decision for everyday errands (MVP: rides, food), personalizes to the user's accessibility profile, then hands off to the real app via deep link. The user always completes the final action themselves.

## Non-negotiables (never violate, even if asked in a prompt or issue)

1. **Never implement order placement, booking, payment, or checkout against any third-party platform.** Hand-off only.
2. **Never implement scraping, headless browsing, UI automation of other apps/sites, or credential storage for third-party services.** No OpenClaw-style agents. Integrations are only: legitimate read-only APIs, documented deep/universal links, or first-party Apple frameworks.
3. **Never fake a capability in UI or demo code paths** (no hardcoded "order placed!" states, no invented menu data, no pretend wheelchair-routing). If data is unavailable, say so in the UI.
4. **Never ship the Anthropic API key in the app.** All LLM calls go through the proxy.
5. **Accessibility criteria in PRD §9 are launch-blocking.** New UI must ship with labels/Dynamic Type/contrast support in the same PR, not "later."
6. **Copy rules:** capability-based language ("for apps that support link hand-off…"), never guaranteed behavior of a named third-party app; short/calm agent voice (≤3 sentences default, max 3 options, one question at a time).

## Architecture

```
[SwiftUI app]
  ├── Features/
  │   ├── Onboarding/        # live-preview onboarding (PRD F1)
  │   ├── Chat/              # conversation UI, TTS/dictation, cards
  │   ├── Profile/           # accessibility toggles + memory ledger
  │   └── Map/               # embedded MapKit views for result cards
  ├── Agent/
  │   ├── AgentClient.swift  # streams from proxy, executes tool calls
  │   ├── Tools/             # search_places, geocode, build_handoff_link, save_preference
  │   ├── SystemPrompt.swift # style contract + injected profile context
  │   └── Transcript.swift   # persisted chat history (SwiftData)
  ├── Handoff/
  │   └── DeepLinkRegistry.swift  # THE ONLY place hand-off URLs are built
  ├── ProfileStore/          # accessibility profile + preference memory (SwiftData)
  └── Services/              # PlacesService, LocationService, Haptics, Speech

[Proxy — separate tiny repo/dir: /proxy]
  Cloudflare Worker (or equivalent): holds ANTHROPIC_API_KEY, forwards
  /v1/messages with enforced model + max_tokens, per-device rate limit.
  No storage. ~50 lines. Never add server-side persistence of conversations.
```

### Agent loop (client-side tool execution)
1. App sends: system prompt (style contract + serialized accessibility profile + preference memory) + transcript + user turn → proxy → Claude (claude-sonnet-4-6, tool use enabled).
2. Claude returns text and/or tool_use blocks. Tools are executed **in Swift on device** (MapKit geocoding, Places HTTP call, registry link construction, memory write). Results are returned as tool_result; loop until final text.
3. Final text renders as chat message; structured card payloads (top-3 list, ride confirm, hand-off card) come back as a JSON tool ("render_card") so UI never regex-parses prose.
4. Enforce style contract mechanically too: max_tokens on proxy, truncate option lists to 3 in the card renderer regardless of model output.

### Data & privacy
- All user data on-device in SwiftData: `AccessibilityProfile`, `PreferenceMemory` (key-value with timestamps, user-visible ledger), `Transcript`.
- LLM requests include only: profile summary, relevant memory keys, conversation. Nothing stored server-side. Location sent as coarse lat/lng only inside tool results when needed for search.
- `save_preference` tool must surface a visible confirmation line in chat and write to the ledger. Provide "delete all memory" in Profile.
- Read `UIAccessibility` statuses (VoiceOver, Reduce Motion, Darker Colors, etc.) at launch and observe notifications; use to seed onboarding defaults and adapt UI. Read-only.

## Integrations (MVP)

| Integration | Type | Tier | Notes |
|---|---|---|---|
| Uber | Deep/universal link | prefilled_action | pickup/dropoff lat,lng + nicknames/formatted address params; product prefill only works with prefilled pickup; can't combine multiple deeplink actions |
| Lyft | Universal link | prefilled_action | `https://lyft.com/ride?id=<ridetype>&pickup[latitude]=..&pickup[longitude]=..&destination[...]=..&partner=<CLIENT_ID>`; get free Client ID (Lyft dev program); falls back to ride.lyft.com web if app absent |
| DoorDash | Universal link | right_page | `https://www.doordash.com/store/<slug>-<id>/` opens store page in app; NO item/cart prefill (that requires signed merchant deeplinks we don't have). Resolve slug via Places name match + web search at build of registry demo set, or link to search page as fallback |
| Google Places API | Read-only REST | data | Nearby/Text Search + Place Details; use `wheelchair_accessible_entrance` & related accessibility attributes when present; key restricted by bundle ID; billing free tier is enough for MVP |
| Apple MapKit | First-party | data/UI | Geocoding (MKLocalSearch/CLGeocoder), MKDirections walking previews, embedded maps. Do NOT claim wheelchair routing — MapKit has none |
| EventKit (optional, if time) | First-party | prefilled_action-equivalent | Creating a reminder/calendar event IS allowed on explicit user request (first-party, user-owned) |

`DeepLinkRegistry` entry shape: `{ platform, tier, urlTemplate, requiredParams, appScheme (for canOpenURL), webFallback, copyLine }`. Add `LSApplicationQueriesSchemes` for uber/lyft/doordash. Every registry change requires on-device manual test noted in the PR description.

## Build/tooling

- Xcode 16+, iOS 17 minimum target (SwiftData, latest accessibility APIs). Swift 5.10+. SwiftUI only, no UIKit unless a specific accessibility behavior requires a representable wrapper (document why).
- No third-party Swift dependencies unless justified in PR (goal: zero for MVP).
- Secrets: Places key in an `.xcconfig` not committed; proxy URL in Info.plist; ANTHROPIC_API_KEY only in proxy env.
- Tests: unit tests for DeepLinkRegistry URL construction (every platform × param combo), profile serialization into system prompt, and card JSON decoding. UI tests: one VoiceOver-path smoke test per vertical using XCUIApplication with accessibility identifiers.

## MCP servers (Model Context Protocol) for developing this project in Claude Code

Configure in `.mcp.json` at repo root (see file). Recommended:
- **XcodeBuildMCP** — lets Claude Code build, run on simulator, read build errors, and drive the simulator; core dev loop for this repo.
- **Figma MCP (official Dev Mode server)** — pull the CEA Figma frames (Chats list, Chat, Profile, Map screens) for pixel-accurate SwiftUI implementation. Requires Figma desktop app / token on the dev machine.
- Do NOT add MCP servers that automate third-party consumer platforms (see Non-negotiable #2) — that constraint applies to dev tooling used to generate app behavior, not just app code.

Note: MCP is dev-time tooling for Claude Code. The shipped iOS app does not use MCP; its agent uses the Claude Messages API with client-executed tools.

## Agent voice — system prompt requirements (keep in SystemPrompt.swift)

- Persona: calm, plain-language helper. No hype, no emoji unless user uses them, no exclamation marks.
- ≤3 sentences per message unless user asks for detail. One question per turn. Max 3 options.
- Always confirm ambiguous slots (destination, which option) before emitting a hand-off card.
- Adapt phrasing to profile: VoiceOver/blind → fully self-describing spoken text (never "see below"); cognitive profile → simplest sentence forms, numbered choices; deaf profile → never reference sounds.
- Never invent venue attributes, menu items, prices, or ETAs not present in tool results; say "that info isn't available."
- When saving memory, state it explicitly in one short line.
- Identity honesty: CEA finds and prepares; the user confirms in the other app. If asked to "just order it," explain in one sentence and hand off.

## Definition of done for any feature PR

1. Compiles, tests pass, no new warnings.
2. VoiceOver pass on the new screens (labels/traits/rotor actions), Dynamic Type XXL screenshot attached.
3. No copy violating capability-language rules.
4. If it touches hand-off: registry test updated + on-device link test noted.
5. PRD cross-reference: which requirement (F1–F5) it satisfies.
