# PRD — CEA (Connecting with Everything, Everywhere)

**Version:** 1.1 (MVP + v1.1 feature pass for iOS app creation competition, theme: Accessibility)
**Platform:** iOS, native Swift/SwiftUI
**Status:** Built through v1.1. This document is the source of truth for scope; §6.5+ describe the v1.1 additions.

---

## 1. One-line summary

CEA is a conversational AI assistant that handles the discovery and decision-making part of everyday errands (rides, food) for users with visual, auditory, cognitive, or mobility needs — then hands off to the real app via deep link so the **user** confirms the final action. One conversation instead of eight apps.

## 2. Problem

People with access needs navigate a stack of single-purpose apps (delivery, rideshare, maps, reviews) that were not designed with them as the primary user. Even when an app technically supports VoiceOver, finishing a task can take many times longer than it does for an able user, across 8–10 screens. Endless option lists are also a cognitive-load problem — which makes this a universal friction, not only a disability one (curb-cut effect).

## 3. Non-negotiable product principles

These override any feature idea that conflicts with them:

1. **CEA never places orders, books, or pays.** It prepares the action and hands off. The user always performs the final confirming tap inside the target app (or inside a first-party Apple surface like Calendar where the user explicitly asked CEA to create the item).
2. **No scraping, no credential-holding, no browser/UI automation of third-party platforms.** No OpenClaw or similar agents driving other companies' apps/sites. Every integration is either (a) a legitimate read-only API, (b) a documented deep link / universal link, (c) a first-party Apple framework, or (d — v1.1) the user's own explicitly-connected automation endpoint (Zapier MCP) strictly for own-account tasks: their calendar, reminders, notes, lists, and messages they asked to send. Credentials stay with the connector vendor (CEA holds only the user-owned endpoint URL); every side effect is shown to the user and runs only after they confirm; marketplace transactions are permanently excluded from this path.
3. **Capability-based promises.** Marketing and in-app copy never guarantees behavior of a named third-party app. Language pattern: "For apps that support link hand-off, CEA completes the action for you — one tap and it's done. For apps that don't, CEA drops you exactly where you need to be."
4. **The app itself must pass an accessibility audit.** An accessibility app that fails a 30-second VoiceOver test is disqualifying. Accessibility acceptance criteria (§9) are launch-blocking, not nice-to-have.
5. **Short, calm AI responses.** Never overstimulating, never walls of text. Clarify before acting when information is ambiguous (location, cuisine, time).
6. **Privacy-first personalization (v1.1: two-tier).** Accessibility profile data is sensitive (disability/health-adjacent): it lives **on-device only**, is never sent anywhere except as context to the LLM call, is never synced to any memory vendor (asserted by unit tests), and is user-editable/erasable at any time. Non-sensitive **preference memory** (favorite cuisines, frequent destinations) keeps its on-device, user-visible, deletable ledger as the source of truth and additionally syncs to a memory vendor (Supermemory) under an anonymous install-scoped namespace so it survives reinstalls; sensitive-looking keys are filtered out of sync, "delete all memory" clears both sides, and the response-adaptation logic built on memory stays in the CEA codebase — the vendor is storage only.

## 4. Target users / personas

Primary personas for MVP (each maps to a demo moment):

- **P1 — Blind / low-vision (VoiceOver user).** Wants voice-first flow: ask for food → hear a short top-3 with rich, spoken-friendly descriptions → hand off. Success = completes the task without ever needing to visually scan a list.
- **P2 — Deaf / hard-of-hearing.** Wants visual/haptic confirmation of everything (no audio-only cues). Ride status and confirmations surface as haptics + on-screen flashes, per profile.
- **P3 — Cognitive / attention needs (incl. ADHD).** Wants max 3 options, plain language, one question at a time, predictable layouts, no autoplaying/moving content.
- **P4 — Mobility needs.** Wants results pre-filtered to step-free/wheelchair-accessible venues and larger touch targets / voice input prominence.
- **P5 — "Everyone else."** Busy, driving, or done comparing 20 options. Gets the same speed benefit with a default profile. (This persona is the pitch's curb-cut argument; it costs nothing extra to serve.)

## 5. MVP scope — two verticals, done properly

### Vertical A: Rides (the "full hand-off" proof)
- User asks for a ride in natural language ("get me to Union Station").
- CEA resolves pickup (current location) and destination (geocoded via MapKit), confirms with the user in one short message.
- CEA offers **Uber and Lyft** hand-off options. Both support pre-filled deep links (pickup, destination, ride type). Lyft requires a free developer Client ID; Uber deep links support pickup/dropoff/product parameters.
- Profile-aware behavior: wheelchair profile → suggest accessible ride types where available and include that in the confirmation summary; deaf profile → after hand-off, CEA offers a haptic/flash notification pattern for "check your ride app" reminders (local notification, since CEA cannot read third-party ride status without partner API access — do not fake this).
- **Demo moment:** one spoken sentence → confirmation → Uber opens with the trip pre-filled → user taps request.

### Vertical B: Food discovery + hand-off
- User asks for food ("Indian food nearby, step-free").
- CEA queries a read-only places source (Google Places API primary; see CLAUDE.md §Integrations) for candidates near the user.
- CEA filters/ranks by profile (wheelchair_accessible_entrance attribute where available, rating, distance, open-now) and returns a **top 3** with short, spoken-friendly descriptions. Follow-up Q&A supported ("tell me more about the second one", "what kind of dishes do they have" — answered from available data; never invent menu items that aren't in the data).
- Hand-off: constructed deep/universal link to the restaurant's DoorDash store page when resolvable, plus fallbacks (Apple Maps directions, phone call button, restaurant website). Copy must reflect reality: this is "lands you on the right page," not "cart is pre-filled."
- **Demo moment (VoiceOver on):** spoken request → top 3 read aloud → "order from the second one" → DoorDash opens on that restaurant's page.

### Supporting feature: embedded map (not its own vertical)
- MapKit map embedded in chat results for food/ride confirmations, styled per profile (larger labels for low-vision, high-contrast mode).
- Walking route preview to a chosen venue via MKDirections.
- **Honesty constraint:** MapKit does not provide true wheelchair-accessible routing data. MVP may display walking routes and label venue accessibility from Places data, but must not claim computed "wheelchair-accessible routes." The Figma's "least/most accessible route" ranking is post-MVP unless a real data source is secured; do not fake it in the demo.

### Explicitly OUT of scope
- Placing orders/reservations of any kind (permanent non-goal, not just MVP).
- OpenTable/reservations vertical; Instacart grocery vertical (Instacart's shopping-list-page API is a strong post-MVP candidate — real cart prefill — but its access approval runs ~30–40 days; apply early, build later).
- Reading live status from third-party apps (ride ETA, order tracking).
- Android, iPad, watchOS.
- Server-side user accounts. (The app is device-local; the backend is a thin LLM proxy that, as of v1.1, also stores **anonymous** per-venue accessibility reports — never conversations, never user identities — and forwards non-sensitive preference memory to the memory vendor.)
- Trusted-contact loop / caregiver oversight (considered for v1.1, deferred).

## 6. Feature requirements

### F1 — Onboarding with live preview
- 3–5 screens max. Each asks one plain-language question about how the user reads, hears, gets around, and communicates (multi-select toggles mirroring the Figma profile: Color Blindness, Low Vision, Larger Text, High Contrast, Blindness, Hearing Impaired, Captions, Mobility, Cognitive/ADHD-friendly mode).
- v1.1: toggling Color Blindness reveals a subtype selector (Protanopia / Deuteranopia / Tritanopia / Achromatopsia, plus "not sure"); status colors adapt per subtype and labels always carry the meaning. The keyboard never persists across onboarding steps (dismissed on send, tap-outside, and step advance).
- **Live preview requirement:** a real (not mocked) preview of the chat UI is visible during onboarding and re-renders immediately as toggles change — e.g., enabling Mobility/voice-first grows the microphone button into a primary control; Larger Text raises the preview's type size; High Contrast switches the palette; Hearing Impaired shows the haptic/flash confirmation pattern.
- First-run also asks permission for location (when-in-use) and notifications, each with a one-sentence plain-language reason.
- Onboarding is skippable ("use standard settings") and every choice is editable later in Profile.
- **Seed from the system where possible:** on first launch, read `UIAccessibility` state (VoiceOver running, Reduce Motion, prefers larger text, etc.) and pre-toggle matching options so users confirm rather than declare. Never write these system settings, only read.

### F2 — Conversational agent
- Text + voice input (system dictation for MVP; mic button prominence is profile-driven). Text-to-speech output via AVSpeechSynthesizer when VoiceOver is off but the user chose spoken responses; when VoiceOver is on, rely on VoiceOver reading the transcript, don't double-speak.
- Response style contract (enforced via system prompt + response length cap):
  - ≤ 3 sentences per message by default; one question at a time.
  - Always confirm ambiguous parameters before hand-off (destination, party size, "which of the 3").
  - Max 3 options presented, ever. "More options" only on explicit request, 3 at a time.
  - Plain language, no jargon, no emoji-spam, no exclamation-mark enthusiasm.
- Every assistant turn that proposes an action ends with exactly one clear next step ("Say 'first one' or tap it to continue.").
- Chat history persists locally (v1.1: reached via the home sidebar rather than a tab).
- v1.1 latency budget (§3.5 — latency is an accessibility feature): responses stream; an instant acknowledgment (haptic tap + visible "Heard you — on it" + VoiceOver announcement) fires the moment input is sent; TTS starts speaking on the first completed sentence, not the full reply; TTS stops immediately on leaving the chat and is never active alongside VoiceOver.
- v1.1 verbosity dial (in-repo ResponseShaper): the response style adapts per profile — terse (power user), simple (cognitive), standard, rich (blind users who want the detail a sighted user gets visually) — via system-prompt directives plus a mechanical sentence-cap post-pass. Automatic by default, user-overridable in Profile.

### F3 — Memory & profile (v1.1: split persistence)
- Two memory layers:
  1. **Accessibility profile** (structured, ON-DEVICE ONLY): the onboarding toggles + derived preferences (voice-first, max option count, haptic confirmations, colorblind subtype, verbosity). Injected into every LLM system prompt. Never synced to any vendor (unit-tested).
  2. **Preference memory** (lightweight, structured key-values the agent may write with user-visible confirmation): favorite cuisines, home/frequent destinations, "most recent order" style references. No free-form diary of the user. Every stored item is viewable and deletable in Profile → Memory. v1.1: also persisted vendor-side (Supermemory via the proxy, anonymous namespace) for continuity; sensitive-looking keys are filtered from sync; deleting (one or all) clears both local and vendor copies.
- Memory writes require the agent to state what it's saving ("Saved: you prefer wheelchair-accessible venues.").

### F4 — Hand-off engine
- A **deep-link registry** (single Swift module) is the only place hand-off URLs are constructed. Each entry declares: platform, capability tier (`prefilled_action` vs `right_page` vs `fallback_web`), URL template, required params, installed-app check (`canOpenURL` with declared `LSApplicationQueriesSchemes`), and web fallback URL.
- Tier behavior in UI copy: prefilled_action → "One tap in [app] and it's done." right_page → "This takes you straight to the right page — a tap or two to finish."
- Every hand-off card shows: what will open, what's pre-filled, and that CEA does not place the order. (One line, not a legal disclaimer wall.)
- If the target app isn't installed → universal link/web fallback, never a dead end.

### F5 — Profile-adaptive UI (the Figma Profile screen)
- All toggles from F1 live here and apply app-wide instantly: type scale, contrast theme, color-blind-safe palette (per subtype), haptic confirmation mode, captions-on-media, voice-first layout, verbosity dial, community-survey opt-out.
- These are **in addition to** honoring system settings (Dynamic Type, Reduce Motion, Increase Contrast, VoiceOver). System settings always win when stricter.

## 6.5 v1.1 additions

### F6 — Chat-first home (redesign)
- No tab bar. Launch opens a fresh chat with the composer ready (never auto-focused — no surprise keyboard for VoiceOver/voice-first users). Top-left opens a slide-over sidebar with the full chat history and Routines; top-right is a small transparent Profile entry point. Floating shortcut widgets (labeled, Reduce-Motion-safe) pre-seed CEA requests or open the user's most-used apps, personalized by on-device usage counts.

### F7 — Haptic vocabulary
- One Core Haptics service with named, distinguishable patterns: `confirmed` (two rising taps), `needs_input` (one soft buzz), `heads_up`/barrier (three sharp taps), `tap`. Applied consistently app-wide; the primary channel for deaf/HoH profiles (that profile implies haptics on). Every pattern has a visual twin already on screen (border-glow flash that never covers content).

### F8 — Focus mode
- One tap collapses the UI into a single card: the one next action in huge type with one confirm button (a real hand-off open when one is pending; otherwise back-to-chat). Honest derivation from the conversation; exit always available; Dynamic Type + Reduce Motion respected.

### F9 — Routines (saved multi-step flows)
- Named, user-created, editable sequences (e.g. "Going home" = ride hand-off + text a contact + set a reminder), triggered by one tap (sidebar) or one utterance (agent). Every step is visible before it runs; steps run strictly in order; ride steps stay hand-offs; message/reminder steps go through the own-account layer (F11) and each requires its own explicit confirm; any step can be skipped.

### F10 — Crowdsourced accessibility data
- After a venue hand-off, CEA queues one short structured question (step-free entry, door width, noise, lighting, accessible bathroom, ASL-friendly staff) and asks it later at a low-pressure moment — a fresh chat, ≥2 h after the hand-off — never mid-task. One question at a time, skippable, and the prompts can be disabled entirely. Reports are anonymous, structured, timestamped, per-venue.
- Result cards surface aggregates with honest provenance ("Step-free entry confirmed by 3 CEA users, last confirmed 2 weeks ago"; "No reports from CEA users yet") and a proactive barrier flag for mobility profiles when reports are majority-negative — never inferred from missing data.

### F11 — Own-account task layer (Zapier MCP)
- Strictly-scoped connector for the user's own calendar events, reminders, notes, personal lists, and messages they explicitly asked to send (see Principle #2d). Available to the agent (`own_account_action`) and to routine steps. Confirm-before-side-effect everywhere: the agent can only render a confirmation card; the action runs when the user taps Confirm.

## 7. AI stack decision (recommendation: Claude API via a thin proxy)

**Decision: Claude API (claude-sonnet-4-6) with tool use, called through a minimal serverless proxy. Not on-device Apple models for the core agent.**

Rationale:
- The agent needs reliable multi-step tool use (search places → rank per profile → construct deep link → confirm), structured JSON output for UI cards, and consistent adherence to a strict response-style contract. Cloud frontier models are dependable at this; current on-device models are not, and a flaky agent is fatal in a live demo and worse for users who depend on it.
- Tool-use pattern: define tools (`search_places`, `geocode`, `build_handoff_link`, `save_preference`) executed client-side in Swift; the model plans, the device acts. This keeps location raw data and profile on device except what's needed in the prompt.
- Proxy (Cloudflare Worker / tiny Vercel function) holds the API key, sets `max_tokens` low (enforces brevity), and rate-limits. **Never ship the Anthropic API key in the app bundle.** For a judged demo this proxy is ~50 lines; acceptable scope.
- Privacy note for the deck/README: conversation text and the minimal profile context go to the LLM per-request; conversations are never stored server-side. (v1.1: the only server-side data is anonymous venue accessibility reports and vendor-synced non-sensitive preference memory — see Principle #6.) State this plainly in-app.
- Post-MVP consideration: route trivial turns (yes/no confirmations) to on-device Apple Foundation Models for latency/cost; not MVP.

## 8. Success metrics (competition framing)

- **Task-time demo metric:** side-by-side timing, VoiceOver on: "order Indian food" via native app flow vs via CEA. Target ≥ 3× faster to reach the confirm screen. Rehearse and record as backup video.
- Zero faked capabilities in the demo (every tap shown is real).
- Full task flow completable with: (a) VoiceOver only, (b) voice input only, (c) largest Dynamic Type size, without layout breakage.
- Onboarding ≤ 90 seconds to first successful request.

## 9. Accessibility acceptance criteria (launch-blocking)

- Every interactive element has an accessibility label, trait, and (where needed) hint; custom chat cells expose combined, sensible VoiceOver elements (one swipe per message, actions via rotor/custom actions).
- Supports Dynamic Type up through accessibility sizes; no truncated critical text; layouts reflow (no fixed-height chat bubbles).
- Contrast ≥ WCAG AA in all themes; color is never the only signal (route ranking uses labels, not just red/yellow, per Figma note).
- Honors Reduce Motion (no parallax/bounce), Reduce Transparency.
- All haptic confirmations have a visual twin; all audio cues have a visual/haptic twin.
- Touch targets ≥ 44×44pt; voice-first profile raises primary targets further.
- Tested with VoiceOver screen-curtain (screen fully off) for the P1 demo flow.

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Deep-link formats change or behave differently than documented | Registry isolates all URLs in one module; every link manually re-tested on-device the week of the demo; web fallbacks defined for each entry |
| Judges probe "so you place the order?" | Principle #1 + capability-language everywhere; team rehearses the answer: discovery is the product, confirmation stays with the user by design (safety + ToS + App Store) |
| Fabricated-feeling stats in pitch (slide 2's "screen-reader task study, 2025") | Replace with a real cited study or with our own measured task-time comparison (§8) |
| LLM latency in live demo | Streaming responses; canned-network backup video; short system prompt |
| Places data lacks accessibility attributes for some venues | Say "accessibility info unavailable" honestly; never guess |
| Profile data sensitivity | On-device storage, visible memory ledger, delete-all button |

## 11. Milestones (adjust to competition deadline)

1. **M0 — Skeleton (week 1):** SwiftUI shell (Chats list, Chat, Profile per Figma), profile store, system-accessibility seeding.
2. **M1 — Agent loop (week 2):** proxy up, Claude tool-use round trip, response-style contract enforced, chat persistence.
3. **M2 — Vertical A (week 3):** geocoding, Uber/Lyft registry entries, ride confirm card, hand-off tested on device.
4. **M3 — Vertical B (week 4):** Places search tool, top-3 ranking with profile filters, DoorDash right-page hand-off, embedded map.
5. **M4 — Onboarding + adaptive UI (week 5):** live-preview onboarding, all profile toggles wired.
6. **M5 — Accessibility hardening + demo (week 6):** §9 audit, VoiceOver rehearsal, timing video, deck sync.
