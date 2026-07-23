# Freewrite Voice Coach Agent

`agent.py` is the LiveKit entrypoint; provider-neutral configuration, prompts,
background deliberation, and telemetry live in `coach/` and are unit-tested.

## Runtime architecture

The macOS Voice Lab sends a versioned `voiceConfig` through the token Worker and
LiveKit participant metadata. `coach/config.py` validates the profile again so
unknown models never silently fall back and contaminate A/B results.

The token Worker also preflights selected voice and strategist providers
against non-secret enabled-provider lists. Keep those lists synchronized with
credentials on this active agent whenever keys are added or removed. Backend
configuration failures are published over telemetry before teardown; the app
does not treat RTC participant presence alone as call readiness.

Two call architectures use the exact same `build_system_prompt`:

- **Cascade (default):** Deepgram Nova-3 → selected text LLM → ElevenLabs
  `eleven_flash_v2_5`, with Silero VAD and LiveKit's current acoustic + semantic
  `TurnDetector`.
- **Native realtime:** OpenAI Realtime, Gemini Flash Live, or Grok Voice owns
  audio understanding, turn-taking, reasoning, and speech generation.

Flux is an advanced cascade experiment. It replaces Nova-3 plus LiveKit's turn
detector with `flux-general-en` and `turn_handling.turn_detection="stt"`. It is not the
default because its integrated EOT value overlaps LiveKit's newer audio-aware
detector, while Nova keeps broader multilingual support and keyterm behavior.

### Profile catalog

| Profile | Architecture | Required provider key |
|---|---|---|
| `cascade-gemini-3.5-flash` (default) | Cascade | Google |
| `cascade-gemini-3.1-flash-lite` | Cascade | Google |
| `cascade-gemini-3-flash-preview` | Cascade | Google |
| `cascade-gemini-2.5-flash` | Cascade baseline | Google |
| `cascade-gpt-5.6-terra` | Cascade | OpenAI |
| `cascade-claude-haiku-4.5` | Cascade | Anthropic |
| `realtime-gpt-2.1` / `realtime-gpt-2.1-mini` | Native | OpenAI |
| `realtime-gemini-3.1-flash-live-preview` | Native | Google |
| `realtime-grok-think-fast` | Native | xAI |

Gemini 3.1 Flash Live is a listen-first profile: its API ignores
`generate_reply`, instruction updates, and chat-context updates after the first
turn. It answers the user's first spoken turn; the in-app console records this
capability rather than pretending an opener or strategist injection succeeded.

## Background strategist

When enabled, `DeliberationCoordinator` snapshots changed transcript turns on a
15/20/30-second cadence (30 seconds by default) and asks the selected Gemini,
Claude Sonnet 5, Claude Opus 4.8, or GPT-5.6 Sol strategist for a small
structured `CoachingBrief`. Provider-valid thinking effort is selectable. This
work is outside the live reply path.

The brief is advisory and contains summary, themes, direction, one recommended
move, candidate questions, risks, and confidence—never hidden chain-of-thought.
It is injected into the complete system context before the next response for
providers that support dynamic instructions and is always available through
`get_coaching_brief`. Gemini Live uses the explicit, observable tool fallback.

## Observability

LiveKit Cloud remains the durable trace/session-recording surface. In addition,
the agent publishes compact JSON on reliable data topic
`freewrite.voice.telemetry`:

- accepted config and lifecycle/capability events;
- sampled cumulative provider usage and estimated list-price cost;
- per-turn EOT, LLM, TTS, playback, and end-to-end latency;
- transcripts, errors, and structured strategist briefs.

The app displays these in a toggleable developer console and saves
`transcript.md`, `meta.json`, `events.json`, and `analyses.json` under
`~/Documents/Freewrite/VoiceSessions/<entry>/<session>/`. Completed sessions are
also inserted into Supabase under RLS. Cost is explicitly an estimate; provider
credits, discounts, cached-token policies, and price changes can differ.

## Local runtime status

> **Not production-ready:** the agent currently runs on Julian's Mac through
> `~/Library/LaunchAgents/ai.julian.freewrite-coach.plist` and logs to
> `/tmp/freewrite-coach.log`. Shipping requires `lk agent deploy` with every
> provider secret, then unloading the local LaunchAgent so two workers do not
> compete for dispatches.

Useful commands:

```bash
launchctl print gui/$UID/ai.julian.freewrite-coach
launchctl kickstart -k gui/$UID/ai.julian.freewrite-coach
tail -f /tmp/freewrite-coach.log
```

`run-agent.sh` is the ad-hoc supervisor fallback and refuses to double-start
while the LaunchAgent is loaded.

## Verification

```bash
./.venv/bin/python -m pytest -q
./.venv/bin/python tools/e2e_probe.py
./.venv/bin/python tools/e2e_probe.py \
  --profile realtime-gemini-3.1-flash-live-preview \
  --user-utterance "I keep avoiding the sales call. What do you notice?"
```

The probe mints the same metadata shape, joins a `freewrite-` room, publishes a
microphone track, and requires audible agent output. `--user-utterance` renders
local macOS speech for listen-first/native pipeline tests without another API.

## Environment

| Variable | Purpose |
|---|---|
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | LiveKit connection, dispatch, and inference |
| `GOOGLE_GEMINI_API_KEY` | Google cascade, Gemini Live, and Gemini strategist |
| `DEEPGRAM_API_KEY` | Cascade STT |
| `ELEVEN_API_KEY` | Cascade TTS (not `ELEVENLABS_API_KEY`) |
| `OPENAI_API_KEY` | OpenAI cascade/realtime profiles and GPT strategist |
| `ANTHROPIC_API_KEY` | Claude cascade profile and Sonnet/Opus strategist |
| `XAI_API_KEY` | Grok native profile |

Optional voice overrides: `COACH_VOICE_ID`, `COACH_OPENAI_VOICE`,
`COACH_GEMINI_VOICE`, `COACH_XAI_VOICE`, and `COACH_AGENT_NAME`.

## Dispatch and prompt invariants

The worker registers as `freewrite-coach` and only accepts opaque room names
beginning `freewrite-`. Room names must not embed user or entry IDs. The SOUL,
voice rules, entry context, strategist contract, and current brief are assembled
only by `coach/prompt.py:build_system_prompt`; provider factories must not fork
their own persona.
