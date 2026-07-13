# CLAUDE.md — CEA (Connecting with Everything, Anywhere)

Claude Code: read this fully before making changes. PRD.md is the product source of truth; this file is the engineering source of truth. If a request conflicts with the Non-negotiables below, flag it instead of implementing it.

## What this project is

Native iOS (Swift/SwiftUI) accessibility-first AI assistant for an iOS app creation competition (theme: Accessibility). A conversational agent handles discovery + decision for everyday errands (MVP: rides, food), personalizes to the user's accessibility profile, then hands off to the real app via deep link. The user always completes the final action themselves.

## Non-negotiables (never violate, even if asked in a prompt or issue)

1. **Never implement order placement, booking, payment, or checkout against any third-party platform.** Hand-off only. (v1.1: the own-account task layer below is NOT an exception — it is scoped to the user's own calendar/reminders/notes/lists/messages and never touches a marketplace.)
2. **Never implement scraping, headless browsing, UI automation of other apps/sites, or credential storage for third-party services.** No OpenClaw-style agents. Integrations are only: legitimate read-only APIs, documented deep/universal links, first-party Apple frameworks, or (v1.1) the user's own explicitly-connected automation endpoint (Zapier MCP) for own-account tasks — where the credentials live with the connector vendor, the app only ever holds the user-owned endpoint URL, and every side effect is confirmed by the user before it runs.
3. **Never fake a capability in UI or demo code paths** (no hardcoded "order placed!" states, no invented menu data, no pretend wheelchair-routing). If data is unavailable, say so in the UI.
4. **Never ship the Anthropic API key in the app.** All LLM calls go through the proxy.
5. **Accessibility criteria in PRD §9 are launch-blocking.** New UI must ship with labels/Dynamic Type/contrast support in the same PR, not "later."
6. **Copy rules:** capability-based language ("for apps that support link hand-off…"), never guaranteed behavior of a named third-party app; short/calm agent voice (≤3 sentences default, max 3 options, one question at a time).

## Architecture

```
[SwiftUI app]
  ├── Features/
  │   ├── Onboarding/        # live-preview onboarding (PRD F1)
  │   ├── Home/              # v1.1: chat-first home (no tab bar), sidebar,
  │   │                      #   floating shortcuts, focus mode, survey prompt
  │   ├── Chat/              # conversation UI, streaming, TTS/dictation, cards
  │   ├── Profile/           # accessibility toggles + memory ledger
  │   └── Map/               # embedded MapKit views for result cards
  ├── Agent/
  │   ├── AgentClient.swift  # SSE streaming from proxy, executes tool calls
  │   ├── Tools/             # search_places, geocode, build_handoff_link,
  │   │                      #   save_preference, own_account_action, run_routine
  │   ├── SystemPrompt.swift # style contract + injected profile context
  │   ├── ResponseShaper.swift # v1.1 §3.6 verbosity dial (prompt + post-pass)
  │   └── Transcript.swift   # persisted chat history (SwiftData)
  ├── Handoff/
  │   └── DeepLinkRegistry.swift  # THE ONLY place hand-off URLs are built
  ├── Routines/              # v1.1: saved multi-step flows (models, editor, runner)
  ├── ProfileStore/          # accessibility profile + preference memory (SwiftData)
  │                          #   + MemoryBackend (v1.1 §5 vendor sync, privacy split)
  └── Services/              # Places, Location, Haptics (Core Haptics vocabulary),
                             #   Speech (streaming TTS), Crowdsource, ZapierMCP

[Proxy — separate tiny repo/dir: /proxy]
  Cloudflare Worker: holds ANTHROPIC_API_KEY (and SUPERMEMORY_API_KEY),
  forwards /v1/messages with enforced model + max_tokens, streaming
  pass-through, per-client rate limit. Conversations are NEVER persisted.
  v1.1 storage exception: POST/GET /reports keeps ANONYMOUS per-venue
  accessibility reports (attribute + yes/no + timestamp; no user IDs,
  no profile data, no IPs) in KV. POST /memory forwards non-sensitive
  preference memory to Supermemory (key server-side only).
```

### Agent loop (client-side tool execution)
1. App sends: system prompt (style contract + verbosity directives + serialized accessibility profile + preference memory) + transcript + user turn → proxy → Claude (claude-sonnet-4-6, tool use enabled), **streamed over SSE** (v1.1 §3.5: instant on-send acknowledgment, first tokens render live, TTS starts on the first completed sentence).
2. Claude returns text and/or tool_use blocks. Tools are executed **in Swift on device** (MapKit geocoding, Places HTTP call, registry link construction, memory write, routine open, own-account confirmation card). Results are returned as tool_result; loop until final text.
3. Final text renders as chat message; structured card payloads (top-3 list, ride confirm, hand-off card, own-account confirm) come back as a JSON tool ("render_card" / emitted by tools) so UI never regex-parses prose.
4. Enforce style contract mechanically too: max_tokens on proxy, truncate option lists to 3 in the card renderer, and ResponseShaper's per-profile sentence caps applied to final text — all regardless of model output.
5. Side-effect rule: `own_account_action` never executes inside the tool loop. It renders a confirmation card; the call to the user's Zapier endpoint fires only on the user's Confirm tap.

### Data & privacy (v1.1 split)
- **The accessibility profile (disability/health-adjacent) lives on-device only** in SwiftData and is never sent anywhere except as the prompt summary inside LLM requests. It is NEVER synced to the memory vendor — enforced by construction (the vendor payload type carries only preference key/value strings) and by MemoryPrivacyTests.
- **Preference memory** (cuisines, frequent destinations — non-sensitive personalization) keeps its on-device, user-visible, deletable ledger as source of truth, and additionally syncs to Supermemory via the proxy under an anonymous install-scoped namespace. Sensitive-looking keys are filtered from sync (local-only). "Delete all memory" clears local AND vendor-side. The profile-shaping logic that turns memory into adapted responses stays in this repo; the vendor is just storage.
- LLM requests include only: profile summary, relevant memory keys, conversation. Conversations are never stored server-side. Location sent as coarse lat/lng only inside tool results when needed for search.
- Crowdsourced venue reports (v1.1 §3.1) are anonymous by construction: attribute + yes/no + venue + timestamp. No user IDs, no profile data. Post-visit survey prompts never interrupt a task (queued; surfaced on a fresh chat ≥2 h later), are one-question-at-a-time, skippable, and can be disabled entirely in Profile.
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
| Zapier MCP (v1.1 §4) | User-owned automation endpoint | own_account | STRICT scope: the user's own calendar events, reminders, notes, personal lists, and messages they explicitly asked to send. NEVER marketplace transactions (rides/food/payments stay on the deep-link hand-off path). User connects their own apps in Zapier; the app holds only the endpoint URL (CEA_ZAPIER_MCP_URL, gitignored xcconfig), never credentials. Every side effect shows a confirmation card and runs only on the user's Confirm. Each call costs a Zapier task + 1–3 s — never speculative |
| Supermemory (v1.1 §5) | Read/write REST via proxy | data | NON-SENSITIVE preference memory only; accessibility profile never leaves the device. Key server-side (SUPERMEMORY_API_KEY). Delete-all clears vendor-side too |
| CEA crowdsource layer (v1.1 §3.1) | Own Worker + KV | data | Anonymous per-venue accessibility reports (structured attribute vocabulary); aggregates surfaced with honest provenance and never presented as verified fact |

`DeepLinkRegistry` entry shape: `{ platform, tier, urlTemplate, requiredParams, appScheme (for canOpenURL), webFallback, copyLine }`. Add `LSApplicationQueriesSchemes` for uber/lyft/doordash. Every registry change requires on-device manual test noted in the PR description.

## Build/tooling

- Xcode 16+, iOS 17 minimum target (SwiftData, latest accessibility APIs). Swift 5.10+. SwiftUI only, no UIKit unless a specific accessibility behavior requires a representable wrapper (document why).
- No third-party Swift dependencies unless justified in PR (goal: zero for MVP).
- Secrets: Places key in an `.xcconfig` not committed; proxy URL in Info.plist; ANTHROPIC_API_KEY only in proxy env.
- Tests: unit tests for DeepLinkRegistry URL construction (every platform × param combo), profile serialization into system prompt, card JSON decoding, and (v1.1) verbosity shaping per profile (ResponseShaperTests), crowdsource report/provenance/survey-timing logic (CrowdsourceTests), routine step execution (RoutineEngineTests), and the memory privacy split — sensitive profile fields never leave the device (MemoryPrivacyTests). UI tests: one VoiceOver-path smoke test per vertical using XCUIApplication with accessibility identifiers (still TODO).

## MCP servers (Model Context Protocol) for developing this project in Claude Code

Configure in `.mcp.json` at repo root (see file). Recommended:
- **XcodeBuildMCP** — lets Claude Code build, run on simulator, read build errors, and drive the simulator; core dev loop for this repo.
- **Figma MCP (official Dev Mode server)** — pull the CEA Figma frames (Chats list, Chat, Profile, Map screens) for pixel-accurate SwiftUI implementation. Requires Figma desktop app / token on the dev machine.
- Do NOT add MCP servers that automate third-party consumer platforms (see Non-negotiable #2) — that constraint applies to dev tooling used to generate app behavior, not just app code.

Note: MCP as dev-time tooling for Claude Code is unrelated to the shipped app's agent loop (Claude Messages API with client-executed tools). v1.1 exception: the shipped app contains one narrowly-scoped MCP *client* — the §4 own-account connector to the user's own Zapier MCP endpoint. It automates nothing of CEA's behavior and never touches third-party consumer platforms on the user's behalf beyond their own accounts, with per-action confirmation.

## Agent voice — system prompt requirements (keep in SystemPrompt.swift)

- Persona: calm, plain-language helper. No hype, no emoji unless user uses them, no exclamation marks.
- ≤3 sentences per message unless user asks for detail. One question per turn. Max 3 options. (v1.1: the verbosity dial — ResponseShaper — adapts this per profile: terse 2, simple 3, rich up to 6; enforced both in the prompt and mechanically on output.)
- Own-account actions (§4): never claim an action happened — it is "ready to confirm" until the user taps Confirm on the card.
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
