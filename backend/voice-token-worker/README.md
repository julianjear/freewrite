# Freewrite AI Gateway Worker

Authenticated edge gateway for both `POST /voice/token` and streaming
`POST /chat/stream`. The chat route drives bounded OpenAI Responses or Anthropic
Messages tool loops and emits the typed SSE contract consumed by `AIChatClient`.
Every final chat answer is a self-contained HTML artifact rendered in an
isolated `WKWebView`; the Worker owns the fixed soul, note context, tool policy,
and the hidden old-friend opening turn.

## Run locally

Wrangler runs this Worker in local `workerd`; a Cloudflare login is not needed
for local development.

```bash
cp .dev.vars.example .dev.vars
# Fill the LiveKit and OpenAI values in .dev.vars (never commit this file).
# Add ANTHROPIC_API_KEY only when testing Claude chat models.
npm install
npm run dev:local
```

Point the macOS app at it, then restart the app:

```bash
defaults write app.julian.freewrite voiceTokenBaseURL http://127.0.0.1:8787
```

Return to the deployed Worker with:

```bash
defaults delete app.julian.freewrite voiceTokenBaseURL
```

The local Worker still verifies a real Supabase access token. An unauthenticated
request to either endpoint returning `401` is the expected shallow smoke test.

`ENABLED_VOICE_PROVIDERS` and `ENABLED_STRATEGIST_PROVIDERS` in `wrangler.toml`
must mirror credentials installed on the active LiveKit agent. They contain no
secrets. The Worker returns a descriptive `409` before creating a room when a
selected provider is unavailable, instead of allowing an agent job to crash
after the UI says it joined.

## Authenticate and deploy as infinite@julian.ai

Run these from this directory with `npx` so the repository-pinned Wrangler
version is used:

```bash
npx wrangler login
# Complete the browser login as infinite@julian.ai.
npx wrangler whoami
npx wrangler secret put OPENAI_API_KEY
# Optional, to enable Claude Sonnet / Opus / Fable in text chat:
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

Complete the browser login with `infinite@julian.ai`, and confirm `whoami`
shows account ID `0b9cb211bb5f049854525d6fdc6182f4` before any secret or deploy
command. Wrangler may display `Active profile: infinite` when that profile is
already selected. (`wrangler login --profile` and `wrangler auth create` are
not valid in Wrangler 4.112.) For non-interactive CI, set a scoped
`CLOUDFLARE_API_TOKEN` instead;
that environment variable takes precedence over stored OAuth credentials.

## Text chat models and observability

- OpenAI: `gpt-5.6-terra`, `gpt-5.6-sol`
- Anthropic: `claude-sonnet-5`, `claude-opus-4-8`, `claude-fable-5`

The app persists the selected chat model, reasoning effort, and observability
toggle in `UserDefaults`. Tool availability and each tool call are visible only
when observability is enabled. Usage events include uncached input, cached
input, cache writes, output, reasoning, hosted-search charges, latency, and a
list-price cost estimate. This is measured usage multiplied by public prices,
not an invoice-settled amount.
