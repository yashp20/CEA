# CEA proxy

Minimal Cloudflare Worker that fronts the OpenAI API for the CEA iOS app
(aligned with Apple Intelligence's ChatGPT integration). It exists so the
OpenAI API key never ships in the app bundle (CLAUDE.md non-negotiable #4).

What it does:

- The app speaks the Anthropic Messages format; the proxy **translates** it to
  `https://api.openai.com/v1/chat/completions` and translates the response
  (including streaming SSE) back — so the iOS agent stays provider-agnostic.
- **Enforces** the model (`gpt-4o`) and caps `max_tokens` at 1024 server-side
  — the app can't override the style contract.
- Best-effort per-IP rate limit (20 req/min, in-memory per isolate).
- **No storage.** Nothing is logged or persisted.

## Deploy

```sh
cd proxy
npx wrangler deploy
npx wrangler secret put OPENAI_API_KEY   # paste your key when prompted
```

Then put the deployed URL in `ios/Secrets.xcconfig`:

```
CEA_PROXY_URL = https:/$()/cea-proxy.<your-subdomain>.workers.dev
```

(The `$()` is xcconfig escaping for `//` — it expands to nothing.)

## Local dev

Two options — both read the key from `.dev.vars` (gitignored):

```sh
echo 'OPENAI_API_KEY=sk-…' > .dev.vars
```

**No Node required** (plain Python, same enforcement as the Worker):

```sh
python3 dev_proxy.py        # listens on http://127.0.0.1:8787
```

The simulator shares the Mac's localhost, so the default
`CEA_PROXY_URL = http://127.0.0.1:8787` in `ios/Secrets.xcconfig` just works
while this is running.

**With Node/wrangler installed:**

```sh
npx wrangler dev
```
