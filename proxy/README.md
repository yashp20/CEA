# CEA proxy

Minimal Cloudflare Worker that fronts the Claude Messages API for the CEA iOS
app. It exists so the Anthropic API key never ships in the app bundle
(CLAUDE.md non-negotiable #4).

What it does:

- Forwards POST bodies to `https://api.anthropic.com/v1/messages`.
- **Enforces** the model (`claude-sonnet-4-6`) and caps `max_tokens` at 1024
  server-side — the app can't override the style contract.
- Best-effort per-IP rate limit (20 req/min, in-memory per isolate).
- **No storage.** Nothing is logged or persisted.

## Deploy

```sh
cd proxy
npx wrangler deploy
npx wrangler secret put ANTHROPIC_API_KEY   # paste your key when prompted
```

Then put the deployed URL in `ios/Secrets.xcconfig`:

```
CEA_PROXY_URL = https:/$()/cea-proxy.<your-subdomain>.workers.dev
```

(The `$()` is xcconfig escaping for `//` — it expands to nothing.)

## Local dev

```sh
echo 'ANTHROPIC_API_KEY=sk-ant-…' > .dev.vars   # gitignored
npx wrangler dev
```
