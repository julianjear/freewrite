# Voice model and architecture research

Snapshot: 2026-07-19. Provider names, preview status, and list prices change;
re-verify official pages before a production rollout.

## Executive decision

Freewrite should keep both architectures because they optimize different things:

1. **Default experiment:** Nova-3 → Gemini 3.5 Flash at low thinking →
   ElevenLabs Flash 2.5, with LiveKit's acoustic + semantic turn detector.
   This gives the cleanest component-level measurements, stable coach voice,
   broad transcription support, and easy LLM substitution.
2. **Best native quality candidate:** GPT-Realtime 2.1. It currently leads the
   independent speech-to-speech reasoning benchmark and has stronger dynamic
   prompt/tool behavior than Gemini Live, but needs an OpenAI key and is much
   more expensive on audio tokens.
3. **Best native Google experiment:** Gemini 3.1 Flash Live Preview. It is low
   cost and expressive, but remains preview and cannot reliably accept
   `generate_reply`, instructions, tools, or chat-history changes after turn one
   through the current Live API. It therefore starts by listening and receives
   strategist guidance through a predeclared tool.
4. **Best independent challenger:** Grok Voice Think Fast. It ranks close to
   GPT-Realtime on independent speech reasoning and has simple $0.05/audio-minute
   pricing, but introduces another provider and has less production evidence in
   this codebase.

There is no current public **Gemini 3.3** model in Google's catalog. The useful
current names are Gemini 3.5 Flash (stable), Gemini 3.1 Flash-Lite (stable),
Gemini 3 Flash Preview, and Gemini 3.1 Flash Live Preview. The UI uses exact API
IDs rather than guessed aliases.

## Current model matrix

Prices below are public pay-as-you-go list prices, not effective account cost.

| Model | Role | Price | Latency/intelligence trade-off | Implementation stance |
|---|---|---:|---|---|
| Gemini 3.5 Flash | Cascade LLM | $1.50 input / $9 output per 1M tokens | Independent testing reports ~157.5 output tok/s and frontier Flash intelligence, but high thinking can add ~27.6s TTFT | Default with low thinking; never high on live path |
| Gemini 3.1 Flash-Lite | Cascade LLM | $0.25 / $1.50 | Lowest cost/latency Google baseline, lower reasoning ceiling | Speed-floor A/B profile |
| Gemini 3 Flash Preview | Cascade LLM | $0.50 / $3 | Preview baseline; superseded in quality by 3.5 Flash | Comparison only |
| Gemini 2.5 Flash | Cascade LLM | $0.30 / $2.50 | Existing known baseline | Regression profile |
| GPT-5.6 Terra | Cascade LLM + text chat | $2.50 / $15 | Fast OpenAI profile with strong instruction following | Default text-chat model at low effort; cascade option |
| Claude Haiku 4.5 | Cascade LLM | $1 / $5 | Good tone/control, lower benchmark intelligence than leaders | Optional tone test |
| Claude Sonnet 5 | Text chat + background strategist | $3 / $15 | Best balance of deliberate analysis, latency, and price among the deep options; adaptive thinking, low through max effort | Primary Claude chat/strategist candidate |
| Claude Opus 4.8 | Text chat + background strategist | $5 / $25 | Stronger deliberation ceiling, but slower and costlier than Sonnet | Quality-ceiling Claude test |
| Claude Fable 5 | Text chat | $10 / $50 | Anthropic's highest-capability model and strongest visual-artifact candidate; highest latency/cost | Deliberate HTML-artifact quality test |
| GPT-5.6 Sol | Text chat + background strategist | $5 / $30 | OpenAI's most capable agentic model; low through max effort, with high output cost | Cross-provider quality-ceiling test |
| GPT-Realtime 2.1 | Native audio | Text $4/$24; audio $32/$64 per 1M tokens | Independent speech-to-speech leader; supports reasoning effort, tools, and interruptions | Primary native candidate |
| GPT-Realtime 2.1 Mini | Native audio | Text $0.60/$2.40; audio $10/$20 | Cheaper/lighter, reduced reasoning quality | Native speed/cost baseline |
| Gemini 3.1 Flash Live Preview | Native audio | Text $0.75/$4.50; audio $3/$12 | Expressive and inexpensive; preview with important session-update limits | Implemented listen-first experiment |
| Grok Voice Think Fast | Native audio | $0.05 per minute of audio sent or received | Independent benchmark places it near GPT-Realtime; straightforward cost | Optional challenger |

Independent Artificial Analysis speech-to-speech scores at this snapshot were
approximately GPT-Realtime 2.1 high 77.2%, Grok Voice Think Fast 75.7%, and
Gemini 3.1 Flash Live high 69.5%. These are useful priors, not Freewrite's
acceptance test: a coaching agent needs reflective pause handling, emotional
specificity, interruption recovery, prompt adherence, and useful next moves.

Sources:

- [Google model catalog](https://ai.google.dev/gemini-api/docs/models), [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing), and [Gemini API changelog](https://ai.google.dev/gemini-api/docs/changelog)
- [Gemini 3.1 Flash Live model](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-flash-live-preview) and [Live API session management](https://ai.google.dev/gemini-api/docs/live-api/session-management)
- [LiveKit Gemini realtime limitations](https://docs.livekit.io/agents/models/realtime/plugins/gemini/)
- [OpenAI GPT-Realtime 2.1](https://developers.openai.com/api/docs/models/gpt-realtime-2.1) and [GPT-Realtime 2.1 Mini](https://developers.openai.com/api/docs/models/gpt-realtime-2.1-mini)
- [OpenAI GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)
- [Anthropic model overview](https://platform.claude.com/docs/en/about-claude/models/overview), [pricing](https://platform.claude.com/docs/en/about-claude/pricing), [adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking), and [effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Artificial Analysis speech-to-speech index](https://artificialanalysis.ai/articles/announcing-the-artificial-analysis-speech-to-speech-index) and [Gemini 3.5 Flash analysis](https://artificialanalysis.ai/models/gemini-3-5-flash/)
- [xAI Voice pricing and capabilities](https://docs.x.ai/developers/models/voice-agent-api)

## STT, turn detection, and TTS

### Nova-3 versus Flux

Deepgram says Flux uses Nova-3 transcription quality plus an integrated turn
state machine, ~260ms p50 EOT detection, eager EOT, and interruption handling.
That is valuable in a traditional VAD-only cascade. It is less decisive here
because LiveKit 1.6's `TurnDetector` listens to audio directly and combines
acoustic cues with semantics. LiveKit's former text multilingual detector is
deprecated.

Defaulting to **Nova-3 + LiveKit TurnDetector** preserves more languages,
keyterms, and a separable EOT metric. Flux remains available as an English-only
A/B strategy (`flux-general-en`, `turn_handling.turn_detection="stt"`, 7-second reflective
pause timeout) so the decision can be changed from measured Freewrite calls.

At this snapshot, Deepgram's displayed promotional streaming prices were
approximately $0.0058/min Nova-3 multilingual, $0.0065/min Flux English, and
$0.0078/min Flux multilingual. Cost is not the deciding factor here.

Sources: [LiveKit turn detector](https://docs.livekit.io/agents/logic/turns/turn-detector/),
[Deepgram Flux migration](https://developers.deepgram.com/docs/flux/nova-3-migration),
and [Deepgram pricing](https://deepgram.com/pricing).

### ElevenLabs

Cascade TTS moves from Turbo 2.5 to **`eleven_flash_v2_5`**. ElevenLabs lists
Flash/Turbo around 75ms model latency and $0.05 per 1,000 characters. We leave
the plugin's aggressive streaming-latency knob unset: the Flash model gives the
large latency win without deliberately trading additional pronunciation and
prosody quality for a few milliseconds.

Source: [ElevenLabs API pricing](https://elevenlabs.io/pricing/api).

## Two-speed coaching design

The fast model must never wait for the strategist. `DeliberationCoordinator`
therefore consumes completed conversation items asynchronously and only runs
when the transcript changed. Every configured interval it asks the deeper model
for a typed `CoachingBrief`:

- one-sentence summary and themes;
- conversation direction or unresolved tension;
- one recommended next move and up to three candidate questions;
- interaction risks and confidence.

The default cadence is 30 seconds. The user can select Gemini 3.1 Pro, Gemini
3.5 Flash, Claude Sonnet 5, Claude Opus 4.8, or GPT-5.6 Sol, plus the effort
levels each provider actually supports. Providers that permit dynamic
instructions receive the complete current brief through the shared prompt
builder before the next response. Every provider also receives a predeclared
`get_coaching_brief` tool. This is both a portability layer and the Gemini Live
fallback. We intentionally do not request, store, or display hidden
chain-of-thought.

Live verification in this worktree: Gemini 3.1 Pro Preview produced a valid
brief in 15.689s from 119 prompt tokens, 213 answer tokens, and 1,661 thinking
tokens. The work ran outside the response path. At list price its estimated
cost was about $0.0227. The main uncertainty is behavioral, not technical:
whether refreshing every 15, 20, or 30 seconds improves coaching enough to
justify prompt churn. The UI exposes all three for evaluation while defaulting
new configurations to 30 seconds.

## Text-chat artifact architecture

The right-side chat uses GPT-5.6 Terra by default, with GPT-5.6 Sol, Claude
Sonnet 5, Claude Opus 4.8, and Claude Fable 5 as persisted choices. The Soul is
the fixed system layer; a private old-friend turn starts each new chat; and the
exact HTML-artifact contract closes every system prompt. Responses render only
after streaming completes in a non-persistent `WKWebView` with a restrictive
CSP. HTTPS images are allowed, while fetch/XHR, frames, forms, external
scripts/styles/fonts/media, local navigation, and automatic popups are blocked.

OpenAI and Anthropic use provider-native hosted web search. Both also receive
bounded custom tools for current-note search, Wikimedia image search, and
public-page reading. Tool starts, inputs, results, duration, citations, cache
usage, reasoning usage, and itemized estimated cost stream to the app. Terra
intentionally offers Low and Medium rather than Minimal in chat because OpenAI
rejects hosted web search at Minimal; silently changing effort would make the
experiment telemetry dishonest.

Production Worker checks on 2026-07-19:

- Authenticated Terra auto-opening returned valid HTML in 6.433s (5,540 input,
  905 output, 35 reasoning tokens; $0.027425 list-price estimate).
- A forced hosted web search returned start/result/citation events and valid
  HTML in 6.362s; the estimate included the $0.01 search charge.
- A forced image search returned four images, reset the pre-tool draft, and
  produced final HTML containing an image in 6.441s.

Claude routes are implemented and unit-tested against captured API envelopes,
including adaptive omitted thinking, structured effort, cache usage, tools,
and `pause_turn` continuation. They deliberately return HTTP 409 in production
until `ANTHROPIC_API_KEY` is installed; no model fallback is hidden from the
experimenter.

## Observability and experiment method

Do not rank profiles by vibes after one call. For every completed user turn,
capture:

- transcription delay and EOT delay;
- LLM first-token time, TTS first-byte time, playback delay, and end-to-end
  response latency;
- interruption count, false interruptions, and recovery;
- provider/model usage and estimated cost;
- final transcript, selected config, errors, and every strategist brief.

The in-app console supports immediate debugging; local JSON/Markdown supports
manual review; Supabase supports session queries under RLS; LiveKit Cloud
provides durable traces, audio, transcripts, and session recordings. Estimated
cost must be reconciled against provider billing before any production claim.
At call end, Freewrite has provider-measured usage quantities and therefore a
much better estimate than a duration-only forecast. It still cannot have the
settled invoice cost immediately: account discounts, credits, minimum billing
increments, LiveKit transport/agent charges, and later vendor adjustments are
separate. Exact effective cost requires later billing-export reconciliation.

Recommended first evaluation set: at least 20 matched conversations per
profile, mixing reflective silence, code-switching, noisy audio, interruptions,
direct factual questions, emotional processing, and explicit requests for
action. Human-score prompt adherence, specificity, emotional attunement, and
usefulness alongside p50/p95 latency.

LiveKit observability sources: [Agent insights](https://docs.livekit.io/deploy/observability/insights/),
[logging](https://docs.livekit.io/agents/ops/logging/), and
[tracing](https://docs.livekit.io/deploy/observability/tracing/).

## Important uncertainties

- Native audio models can sound emotionally aware without actually using
  acoustic evidence reliably. Recent research finds that some voice models
  behave much like transcript-only systems; Freewrite needs its own acoustic
  ablations rather than assuming native audio wins empathy.
- Gemini Live's preview API and update limitations may change. Its tool-only
  strategist integration is a workaround, not equivalent to guaranteed
  instruction injection.
- Anthropic and xAI voice/strategist profiles remain unavailable until their
  local agent keys are configured. OpenAI and Google are configured.
- Provider list prices and independent benchmark results are snapshots.
- The Worker is deployed under `infinite@julian.ai`; the latest verified version
  at this snapshot is `a542364e-083e-4d40-a6d9-e5eb9345904a`.

The restarted local agent also passed a real GPT-Realtime 2.1 LiveKit probe on
2026-07-19: it joined, transcribed the synthetic user turn, emitted repeated
session-usage events, entered speaking state, and delivered audible audio.

Relevant papers: [Real-Time Voice AI Hears but Does Not Listen](https://arxiv.org/abs/2606.26083)
and [Full-Duplex-Bench v3](https://arxiv.org/abs/2604.04847).
