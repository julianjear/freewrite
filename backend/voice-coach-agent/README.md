# Freewrite Voice Coach Agent

Pure logic lives in `coach/` (unit-tested, no livekit import). `agent.py` is the
LiveKit entrypoint.

## Test (offline)

    python3 -m venv .venv && ./.venv/bin/pip install -r requirements-dev.txt
    ./.venv/bin/python -m pytest -v

## Run locally (needs creds in .env)

    pip install -r requirements.txt
    python agent.py dev

## Required env

LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, DEEPGRAM_API_KEY,
ELEVENLABS_API_KEY, CF_AI_GATEWAY_URL, CF_AI_GATEWAY_KEY, COACH_LLM_MODEL,
COACH_AGENT_NAME=freewrite-coach

## Deploy (LiveKit Cloud)

    lk agent create     # first time; writes livekit.toml
    lk agent deploy

## Note on LLM provider (spec 5.4)

`_build_llm()` defaults to Gemini via Cloudflare AI Gateway (OpenAI-compatible
base_url) so voice LLM spend is observable in Cloudflare. Switch to native
Gemini or Claude by editing only that function.

## Runtime-verify (first `python agent.py dev`)

The livekit-agents 1.5 import paths (`livekit.plugins.turn_detector.multilingual`,
`openai.LLM(base_url=...)`, `WorkerOptions` fields) must match the installed
version — adjust to Jungle's working `agent.py` if any import differs. This file
is thin glue; the logic is the tested `coach/` package.
