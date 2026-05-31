# Freewrite Voice Coach Agent

Pure logic lives in `coach/` (unit-tested, no livekit import). `agent.py` is the
LiveKit entrypoint. Stack mirrors Jungle: Deepgram STT → native Gemini LLM →
ElevenLabs TTS, with Silero VAD + the multilingual turn detector.

## Test (offline)

    python3 -m venv .venv && ./.venv/bin/pip install -r requirements-dev.txt
    ./.venv/bin/python -m pytest -v

## Run locally

    pip install -r requirements.txt
    python agent.py dev      # connects to $LIVEKIT_URL, waits for freewrite-* rooms

## Required env (secrets — set in LiveKit Cloud, or a local .env)

| Var | Purpose |
|-----|---------|
| `LIVEKIT_URL` | wss URL of the LiveKit project (reused from Jungle) |
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | LiveKit project creds |
| `GOOGLE_GEMINI_API_KEY` | Gemini Developer API key (the LLM) |
| `DEEPGRAM_API_KEY` | STT |
| `ELEVEN_API_KEY` | TTS — **note the `ELEVEN_` prefix, not `ELEVENLABS_`** |

Optional overrides: `COACH_LLM_MODEL` (default `gemini-2.5-flash`),
`COACH_VOICE_ID` (default set in agent.py), `COACH_AGENT_NAME`
(default `freewrite-coach`).

## Deploy (LiveKit Cloud managed agents)

    lk agent create     # first time — registers the agent, writes livekit.toml
    lk agent deploy     # builds the Dockerfile + ships it

The Dockerfile copies `agent.py` + the `coach/` package and pre-downloads the
turn-detector / VAD models (`python agent.py download-files`) so the container
doesn't crash on a missing model at startup.

## Dispatch / isolation

Registered under `agent_name = freewrite-coach`. `_request_fnc` only accepts
rooms whose name starts with `freewrite-` (the Worker mints
`freewrite-<userId>-<entry>-<ts>`), so it never picks up another project's
calls even though it shares the Jungle LiveKit project.

## LLM provider (spec 5.4)

`_build_llm()` uses **native Gemini** (`google.LLM` + `GOOGLE_GEMINI_API_KEY`) —
Jungle's proven path. To route through Cloudflare AI Gateway later for cost
observability, swap that one function to `openai.LLM(base_url=<gateway>/compat)`.
