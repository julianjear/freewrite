# Freewrite Voice Coach Agent

Pure logic lives in `coach/` (unit-tested, no livekit import). `agent.py` is the
LiveKit entrypoint. Stack mirrors Jungle: Deepgram STT → native Gemini LLM →
ElevenLabs TTS, with Silero VAD + the multilingual turn detector.

> ## ⚠️ NOT PROD-READY: the agent runs LOCALLY on Julian's Mac
>
> The coach currently runs as a **local process on one machine** (managed by a
> launchd LaunchAgent — see below). This is a deliberate dev-speed choice:
> local runs make prompt/pipeline iteration instant.
>
> **Before this feature ships to anyone else, the agent MUST be deployed to
> LiveKit Cloud** (`lk agent deploy` — Dockerfile is ready). Until then:
> - Voice only works while Julian's Mac is on and logged in.
> - Every reboot briefly interrupts the agent (launchd restarts it at login).
> - If the worktree moves/merges, the LaunchAgent's paths must be updated.
>
> Deploy checklist when the time comes: `lk cloud auth` (link the freeflow
> project) → `lk agent create` → `lk agent deploy` → set the secrets from
> `.env` in LiveKit Cloud → `launchctl bootout gui/$UID/ai.julian.freewrite-coach`
> and delete the plist so local + cloud don't both serve dispatches.

## How it runs today (local dev)

A **launchd LaunchAgent** (`~/Library/LaunchAgents/ai.julian.freewrite-coach.plist`)
starts the agent at login and auto-restarts it if it crashes (verified by
kill-test). It runs `.venv/bin/python agent.py dev` from THIS directory —
absolute paths, so keep the worktree in place or update the plist.

    launchctl print  gui/$UID/ai.julian.freewrite-coach   # status
    launchctl kickstart -k gui/$UID/ai.julian.freewrite-coach  # force restart
    launchctl bootout   gui/$UID/ai.julian.freewrite-coach     # stop + disable
    tail -f /tmp/freewrite-coach.log                           # logs

`run-agent.sh` (start/stop/status) is the ad-hoc fallback — it refuses to start
if the LaunchAgent is loaded, so the two can't double-serve.

## Verify end-to-end without a human

    ./.venv/bin/python tools/e2e_probe.py

Mints a token exactly like the Cloudflare Worker (same metadata, same
`freewrite-` room prefix, same explicit dispatch), joins, publishes a mic
track, then measures the coach's TTS audio and prints the transcript.
PASS = agent joined AND spoke audibly. Exit codes: 1 never joined (agent
down?), 2 no audio track, 3 silent audio (TTS key?). **Run this first when
"the coach doesn't speak."**

## Test the pure logic (offline)

    ./.venv/bin/python -m pytest -v

## Required env (secrets — local `.env` today; LiveKit Cloud secrets when deployed)

| Var | Purpose |
|-----|---------|
| `LIVEKIT_URL` | wss URL of the LiveKit project (freeflow) |
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | LiveKit project creds |
| `GOOGLE_GEMINI_API_KEY` | Gemini Developer API key (the LLM) |
| `DEEPGRAM_API_KEY` | STT |
| `ELEVEN_API_KEY` | TTS — **note the `ELEVEN_` prefix, not `ELEVENLABS_`** |

Optional overrides: `COACH_LLM_MODEL` (default `gemini-2.5-flash`),
`COACH_VOICE_ID` (default set in agent.py), `COACH_AGENT_NAME`
(default `freewrite-coach`).

## Dispatch / isolation

Registered under `agent_name = freewrite-coach`. `_request_fnc` only accepts
rooms whose name starts with `freewrite-` (the Worker mints
`freewrite-<userId>-<entry>-<ts>`), so it never picks up another project's
calls even though it shares LiveKit infra conventions with Jungle.

## Prompt

`coach/prompt.py` = the SOUL persona + a voice-session frame (live call inside
Freewrite right after a writing session; short TTS-safe spoken turns) + the
entry context injected by `build_system_prompt`. The opener is spoken via
`session.say()` (no LLM roundtrip → first words ~2s after join).

## LLM provider (spec 5.4)

`_build_llm()` uses **native Gemini** (`google.LLM` + `GOOGLE_GEMINI_API_KEY`) —
Jungle's proven path. To route through Cloudflare AI Gateway later for cost
observability, swap that one function to `openai.LLM(base_url=<gateway>/compat)`.
