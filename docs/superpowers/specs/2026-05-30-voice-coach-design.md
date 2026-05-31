# Voice Coach — Design Spec

- **Date:** 2026-05-30
- **Status:** Draft for review
- **Author:** Julian + Claude (co-design)
- **Target app:** Freewrite (native macOS, SwiftUI)
- **Source to copy from:** `jungle-front-n-back` ("Jungle only", per decision)

---

## 1. Goal

Add a **"Voice" button** next to the existing "Chat" button in Freewrite's bottom-right nav. Pressing it starts a **spoken conversation with an AI coach** that already knows the **current entry** (text entry → its markdown; video entry → its saved transcript). The coach's job is **clarity and depth** — helping the writer understand who they are, go deeper, and find clarity — an *AI coach*, not an *AI tutor*.

This is the first slice of a larger voice experience. We copy as much infrastructure and prompt structure as possible from Jungle, adapting the persona/tools to coaching.

---

## 2. Decisions locked (from co-design Q&A)

| Decision | Choice |
|---|---|
| Source repo | **Jungle only** (`/Users/julianalvarez/jungle-front-n-back`) |
| v1 scope | **Thin slice**: live voice conversation that knows the current entry + transcript persistence |
| Access control | **Supabase Auth, Google sign-in only**; gate the voice feature behind sign-in |
| Data persistence | Save voice-session data **both locally and to Supabase (cloud)** |
| Coach tools (v1) | **None in v1** (thin slice). Tool roadmap decided below for later phases. |
| Voice pipeline | **STT → LLM → TTS** with **Claude** as the LLM (not realtime speech-to-speech) |
| Agent hosting | **LiveKit Cloud managed agents** (Python worker) |
| AI call routing | All LLM calls (voice + future non-voice) routed through **Cloudflare AI Gateway** |
| API keys | Reuse Jungle's keys for now; store via `wrangler secret put` / Supabase secrets, never committed |

### Two flags accepted as part of "Jungle only"

1. **Jungle has no native Swift client.** Its voice client is React/TS (`jungle-web2/src/voice/`). The macOS Swift voice client is therefore **written fresh**, using Jungle's web client as the behavioral spec (state machine, error taxonomy, data-channel protocol) and the official LiveKit Swift SDK.
2. **Jungle auth is Firebase; we want Supabase.** We copy Jungle's Cloudflare Worker structure but **replace the auth layer with Supabase JWT verification** (standard `jose` verification, built fresh).

---

## 3. Non-goals (v1) — YAGNI

Explicitly **out of scope** for v1, deferred to later phases:

- Coach tools (capture insight, set intention, themes, RAG recall, prompt suggestion).
- Post-session AI summary / insight extraction (the "other LLM calls").
- RAG over past entries.
- **Full journal-entry cloud sync.** Only *voice-session* data syncs to the cloud in v1; the journal itself stays local-first.
- Realtime speech-to-speech.
- Multi-language, voice selection UI, analytics dashboards.
- Visual/artifact tools (Jungle's `render_diagram`/`render_table`/`image_search` — wrong modality for a coach; dropped entirely).

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Freewrite (macOS, SwiftUI)                                                    │
│   • "Voice" button (bottom nav, next to Chat)                                  │
│   • VoiceCoachOverlay (connecting / listening / speaking / ended)             │
│   • Supabase Swift SDK  → Google sign-in (ASWebAuthenticationSession)         │
│   • LiveKit Swift SDK   → mic publish / agent-audio subscribe                  │
└───────┬───────────────────────┬───────────────────────────────┬──────────────┘
        │ (1) Google OAuth        │ (2) POST /token               │ (4) WebRTC audio
        │     (PKCE)              │     Bearer <Supabase JWT>     │
        ▼                         ▼     body: {entry context}     ▼
 ┌──────────────┐      ┌─────────────────────────┐      ┌────────────────────────┐
 │ Supabase     │      │ Cloudflare Worker        │      │ LiveKit Cloud (SFU)    │
 │  Auth (Google)│◄────│  • verify Supabase JWT   │      │  media + room dispatch │
 │  Postgres+RLS│      │  • sign LiveKit JWT      │      └───────────┬────────────┘
 │  voice_sessions     │  • embed entry context   │                  │ (3) dispatch job
 └──────▲───────┘      │    in token metadata     │                  ▼
        │              │  • return {token, wsUrl} │      ┌────────────────────────┐
        │ (5) persist  └─────────────────────────┘      │ Python Agent           │
        │ transcript                                     │ (LiveKit Cloud managed)│
        │ (local + cloud)                                │  STT → LLM → TTS       │
        │                                                │  Deepgram│Claude│Cartesia│
        └────────────────────────────────────────────────┤            │           │
                                                          └────────────┼───────────┘
                                                                       ▼
                                                           Cloudflare AI Gateway
                                                           (LLM routing, cost,
                                                            observability, caching)
```

**Why this shape (answering the original architecture questions):**

- The agent is a **long-lived Python worker** holding a WebSocket + WebRTC session. It **cannot** run on Cloudflare Workers / serverless. It runs on **LiveKit Cloud managed agents** (`lk agent create`).
- The **token endpoint** is a stateless JWT signer — a perfect Cloudflare Worker (LiveKit's JS SDK signs via Web Crypto, runs on Workers).
- The **voice LLM** call originates inside the Python agent; we point it at **Cloudflare AI Gateway** via `base_url`, so even voice-model spend is observable in Cloudflare.
- **Future non-voice LLM calls** (summaries/insights) run as a separate Cloudflare Worker → AI Gateway → Claude. Net: one Cloudflare AI Gateway for *all* model spend.

---

## 5. Components

Each component is independently understandable and testable.

### 5.1 Swift client — `VoiceCoach` feature (NEW)

**Purpose:** Own the entire client side of a voice session.

Proposed files (new, isolated from `ContentView.swift` to avoid growing the 2,500-line file further):

- `VoiceCoachButton` — the bottom-nav button (mirrors the Chat button's hover/cursor styling). Disabled while a video recording is active (mic contention) and while no auth session can be established.
- `VoiceCoachOverlay.swift` — the session UI, presented via `.overlay` (same pattern as `VideoRecordingView`), animations disabled for open/close (matches the video recorder convention).
- `VoiceCoachManager.swift` — `@MainActor ObservableObject`. Owns the LiveKit `Room`, connection lifecycle, mute, mic-level polling for the waveform, transcription capture, and disconnect. State enum: `.idle → .authenticating → .connecting → .listening → .speaking → .ended/.error`. (Behavioral spec mirrored from Jungle web `VoiceState`.)
- `VoiceTokenClient.swift` — `POST {workerURL}/voice/token` with `Authorization: Bearer <supabase access token>`; body `{ context, entryRef }`; decodes `{ token, wsUrl, sessionId }`.
- `VoiceTranscriptStore.swift` — collects transcription segments during the session; on end, writes locally + uploads to Supabase.
- `VoiceWaveform.swift` — simple amplitude visualization driven by `room.localParticipant.audioLevel` (and the agent participant's level when speaking). Built fresh; minimalist to match Freewrite.

**Dependencies:** LiveKit Swift SDK (`https://github.com/livekit/client-sdk-swift`, `import LiveKit`, 2.x), Supabase Swift SDK (`supabase-swift`), AppKit.

**Connection flow** (written fresh, behavior from Jungle web):
```
token = VoiceTokenClient.mint(context, entryRef)
room = Room()
try await room.connect(url: token.wsUrl, token: token.token,
                       roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
try await room.localParticipant.setMicrophone(enabled: true)
// remote agent audio auto-subscribes + auto-plays on macOS
register transcription stream handler (lk.transcription)
poll audioLevel for waveform; watch connectionState for drops
```

> macOS note: **do not** use `AVAudioSession` (iOS-only). The LiveKit SDK manages macOS audio internally.

### 5.2 Supabase — Auth + cloud storage (NEW backend dependency)

**Purpose:** Identity (Google-only) and cloud persistence of voice sessions.

- **Auth:** Supabase Auth with Google provider only. Client uses `supabase-swift` with PKCE + `ASWebAuthenticationSession`. Requires a registered URL scheme for the OAuth redirect (e.g. `freewrite://auth-callback`). Session/refresh tokens stored in the **Keychain** (handled by the SDK).
- **DB:** `voice_sessions` table (schema in §8) with **Row-Level Security** so a user can only read/write their own rows.
- **Product framing:** Writing stays 100% account-free. **Only the Voice Coach requires sign-in.** First press of Voice → Google sign-in sheet → then the session.

### 5.3 Cloudflare Worker — token endpoint (COPY from Jungle, swap auth)

**Purpose:** Verify the caller and mint a short-lived LiveKit join token carrying the entry context.

Copied structure from `jungle-backend2/cloudflare-worker/src/routes/livekit-routes.ts`, with changes:

- **Auth:** replace Firebase ID-token verification with **Supabase JWT verification** (`jose`, Supabase project JWKS / JWT secret; verify `iss`, `aud`, `exp`).
- **LiveKit JWT:** keep the hand-signed HS256 token (Web Crypto) with grants `roomJoin, canPublish, canPublishData, canSubscribe, canUpdateOwnMetadata`, scoped to one room. TTL kept short (e.g. **20 min**, our session cap).
- **Room name:** `freewrite-<userId>-<entryId|transient>-<ts>`.
- **Agent dispatch:** keep `roomConfig.agents: [{ agentName: "freewrite-coach" }]` (explicit dispatch, matching Jungle).
- **Context → metadata:** embed `{ userId, context }` in the token `metadata` claim (see §7 for the size-cap handling).
- **Returns:** `{ token, wsUrl: LIVEKIT_URL, sessionId: roomName }`.

### 5.4 Python agent — `freewrite-coach` (COPY from Jungle, re-persona)

**Purpose:** Join the room, read the entry context, run the STT→LLM→TTS coaching loop.

Copied from `jungle-backend2/agents/jungle-voice-agent/` (LiveKit Agents 1.x, `AgentSession`). Changes:

- **Persona/prompt:** new coach prompt module (see §10). Drop the tutor "soul"; keep the *builder pattern* that injects per-session context.
- **Context read:** at job start, `meta = json.loads(participant.metadata); context = meta.get("context")` → build the system prompt + a context-aware opener.
- **Pipeline:** `AgentSession(stt=Deepgram, llm=Claude (Anthropic plugin, base_url → Cloudflare AI Gateway), tts=<Jungle's TTS, default Cartesia>, vad=Silero, turn_detection=<LiveKit default>)`.
  > **Confirm at implementation:** read `requirements.txt` + the actual `AgentSession(...)` in `agent.py` and match Jungle's exact STT/TTS versions and the turn-detection setup. We deliberately set the **LLM to Claude** for coaching quality; if Jungle uses another LLM, that's our one intentional swap.
- **Dispatch:** register under `agent_name="freewrite-coach"`; defensive `request_fnc` accepting only our room-name pattern.
- **No DB writes in v1:** the agent stays stateless; the **client** persists the transcript (keeps agent simple and avoids giving it Supabase creds in v1).

### 5.5 Cloudflare AI Gateway (CONFIG)

**Purpose:** Single chokepoint for all model spend — caching, rate-limiting, cost, observability.

- Agent's Claude calls routed via the gateway's endpoint (`base_url`).
- Free tier covers our volume; no token markup.

---

## 6. Session lifecycle (data flow)

1. User presses **Voice**. If not signed in → Google sign-in sheet (Supabase). On success, continue.
2. Client assembles **context** from the current entry (§7) and calls `VoiceTokenClient.mint`.
3. Worker verifies Supabase JWT, derives room name, embeds context in token metadata, signs LiveKit JWT, returns `{token, wsUrl, sessionId}`.
4. Client `room.connect(...)`, enables mic. Overlay shows **connecting**.
5. LiveKit dispatches the `freewrite-coach` agent into the room. Agent reads `participant.metadata.context`, builds prompt + opener, greets the user referencing what they wrote.
6. Conversation runs: STT (Deepgram) → LLM (Claude via AI Gateway) → TTS (Cartesia). Client renders **listening/speaking** state + waveform; transcription streams to the client.
7. User ends (button) or session hits the **20-min cap** (auto-end). Client disconnects, agent leaves.
8. Client **persists the transcript** locally (§8) and uploads a `voice_sessions` row to Supabase. Overlay shows a brief **ended** state, then closes back to the entry.

---

## 7. Context passing — entry → agent

**Mechanism (copied):** entry context is JSON-serialized → sent in the token-mint POST body → embedded by the Worker into the LiveKit JWT `metadata` claim → read by the agent as `participant.metadata`. No second API call, no agent DB access.

**Context payload (`Codable`):**
```
{
  "entryType": "text" | "video",
  "entryDate": "MMM d",          // display date for natural reference
  "entryText": String?,          // text entry body  OR  video transcript (capped)
  "hasTranscript": Bool,         // video entries: false if transcription missing
  "modality": "voice"
}
```

**Mapping:**
- **Text entry** → `entryText` = entry markdown.
- **Video entry** → `entryText` = the saved `transcript.md` for that entry; `hasTranscript=false` if none (coach opens by asking what the video was about).
- **Empty entry** → `entryText` empty; coach opens open-ended ("What's on your mind?").

**⚠️ Size risk + mitigation (self-review catch):** Freewrite supports long-form entries (thousands of words). JWTs (and the HTTP header carrying them) have practical size limits, so a full long entry in token metadata can break the mint/connect.
- **v1:** cap embedded `entryText` to the **most recent ~6 KB** of the entry (recent writing is most relevant), and include a `truncated: Bool` flag so the coach can acknowledge it's seeing a portion.
- **Upgrade path (documented, not built in v1):** after `room.connect`, the client publishes the full entry text to the agent via a **LiveKit data message / RPC**; the agent waits for it before composing the prompt. Removes the size limit entirely. Build this when long-entry coaching becomes a priority.

**Trust:** token metadata is client-supplied. The Worker layers server-known fields (`userId`) on top and the agent must not trust client-supplied control fields (model/voice selection) — allowlist server-side, mirroring Jungle.

---

## 8. Data model

### 8.1 Local (mirrors Freewrite's existing per-entry directory convention)

Freewrite already stores video media + `transcript.md` under `~/Documents/Freewrite/Videos/[entry-base]/`. Mirror that for voice:

```
~/Documents/Freewrite/VoiceSessions/[entry-base]/[sessionId]/
  ├── transcript.md     # the coaching conversation (speaker-labeled)
  └── meta.json         # { sessionId, entryRef, startedAt, endedAt, durationSec, model }
```

### 8.2 Cloud (Supabase)

```sql
create table voice_sessions (
  id           uuid primary key,            -- = sessionId / room name suffix
  user_id      uuid not null references auth.users(id),
  entry_ref    text,                        -- entry filename/base; null for transient
  entry_type   text,                        -- 'text' | 'video'
  started_at   timestamptz not null,
  ended_at     timestamptz,
  duration_sec int,
  transcript   text,                        -- speaker-labeled conversation
  model        text,                        -- e.g. 'claude-...'
  created_at   timestamptz default now()
);
alter table voice_sessions enable row level security;
create policy "own rows" on voice_sessions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

Local and cloud are written from the **same client code path** on session end; cloud upload failures are non-fatal (local is the source of truth) and retried opportunistically.

---

## 9. Privacy & data flow (self-review catch — important for a journaling app)

Journal content is deeply personal. v1 sends data off-device along the voice path; this must be intentional and transparent:

- **Leaves the device:** the (capped) entry text → Worker → token metadata → agent; audio → Deepgram (STT); text → Claude (LLM, via Cloudflare AI Gateway); agent text → Cartesia (TTS); the conversation transcript → Supabase.
- **Stays local-first:** the journal entries themselves are **not** synced (only voice-session transcripts go to the cloud).
- **Controls:** RLS on `voice_sessions`; short token TTL; Supabase tokens in Keychain; secrets server-side only.
- **Consent:** first voice use shows a one-time, plain-language note that the conversation uses cloud AI services and is saved to your account. (Copy TBD by Julian.)
- **Provider data retention:** prefer zero-retention provider settings where available (confirm at implementation).

This section follows the spirit of the project's analytics/PII rules (no journal text in analytics events; product data flows are explicit and minimized).

---

## 10. Prompt & tools

### 10.1 Prompt module (copy Jungle's *structure*, new persona)

Mirror Jungle's `ai_tutor_agent/prompts/` split:
- `soul.py` (or `persona.py`) — the coach's voice/character. **Placeholder coach persona for v1; Julian writes the real prompt.**
- `system_prompt.py` — `build_system_prompt(context)` that injects the entry context, date, truncation flag, and a coaching frame ("clarity, depth, self-understanding; ask, don't lecture; reflect back the writer's own words").
- Opener logic that references what the writer wrote (or opens open-ended when empty/no transcript).

The **context-injection contract** is the load-bearing part to copy correctly; the prose is Julian's to refine.

### 10.2 Tool roadmap (decided; none ship in v1)

Coach tools **capture**, they don't display. All Jungle tutor/visual tools are dropped.

- **Phase 2 (first):** `capture_insight` (save a realization in the writer's own words) + `set_intention` (a commitment / next step). Highest leverage — every session yields durable artifacts.
- **Phase 2 fast-follow:** `name_theme` (tag recurring patterns the coach hears).
- **Phase 3:** `recall_past_entries` (RAG over the journal; Supabase `pgvector`) + `suggest_writing_prompt` (seed the next freewrite).

Tool results will be delivered to the client via the LiveKit **data channel** (Jungle's `voice_artifact` pattern) and written into local files (and Supabase), keeping data local-first.

---

## 11. UI / UX (high-level; detailed design at implementation)

- **Button:** "Voice" in the bottom-right nav, immediately adjacent to "Chat", same `•`-separated styling, hover → pointing-hand cursor. (Chat button is at `ContentView.swift:1458`; insert alongside.)
- **Overlay:** presented like the video recorder (`.overlay`, no transition animation). Minimalist, matches Freewrite's calm aesthetic; honors light/dark `colorScheme`.
- **States:** connecting (spinner) → active (waveform + listening/speaking cue) → ended. Controls: **mute** and **end**. Optional remaining-time hint near the cap.
- **Mic contention (self-review catch):** Voice and the video recorder are **mutually exclusive** — disable Voice while recording video and vice-versa; ensure full mic release between a video recording and a voice session.
- **Empty/short entry:** Voice is allowed; coach opens open-ended. (Unlike Chat, which blocks on the welcome entry.)

Detailed visual design (waveform, spacing, motion) is done at implementation, applying the project's UI self-critique / design principles.

---

## 12. Auth flow (OAuth in a sandboxed app)

- Add `supabase-swift` (SPM). Configure Google provider in Supabase.
- Sign-in: `ASWebAuthenticationSession` (works under sandbox) with PKCE; redirect via registered URL scheme `freewrite://auth-callback`.
- Tokens persisted in Keychain by the SDK; refresh handled automatically.
- The token-mint call attaches the current Supabase access token as `Authorization: Bearer`.

---

## 13. Configuration & secrets

- **Cloudflare Worker (secrets, never committed):** `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `SUPABASE_JWT_SECRET` (or project ref for JWKS), AI-gateway/provider keys as needed.
- **Python agent (LiveKit Cloud secrets):** `LIVEKIT_URL/API_KEY/API_SECRET`, `DEEPGRAM_API_KEY`, `ANTHROPIC_API_KEY` (or AI-Gateway key + `base_url`), `CARTESIA_API_KEY` (confirm), `JUNGLE_AGENT_NAME=freewrite-coach`.
- **App:** Supabase URL + anon key (anon key is publishable), Worker base URL, LiveKit not needed client-side beyond the returned `wsUrl`.
- Reuse Jungle's keys initially; migrate to fresh keys later (Julian).

---

## 14. Error handling

Per-stage, surfaced as a compact overlay message (mirroring Jungle's error taxonomy):

- **Auth failure / cancel** → return to entry, no session; offer retry.
- **Permission denied (mic)** → reuse Freewrite's mic-permission popover pattern; deep-link to System Settings.
- **Token mint fail (401 / network / 5xx)** → "Couldn't start the coach" + retry; classify by HTTP status.
- **Room connect fail** → distinct message; retry.
- **Agent never joins (dispatch timeout)** → time out after N seconds with a clear message.
- **Unexpected disconnect** → detect via `connectionState` watch; distinguish token expiry vs network; offer reconnect.
- **TTS/STT/LLM provider error** → agent degrades gracefully (spoken apology); client logs.
- **Cloud upload fail** → silent; local transcript is source of truth; retry later.

---

## 15. Cost & guardrails

- Low-volume estimate: **~$0–60/mo**, dominated by TTS. Pipeline (Claude) chosen partly because realtime S2S is ~3–5× the cost and can't use Claude.
- **Guardrails:** session cap **20 min** (token TTL + client timer + agent-side limit); one concurrent session per user; agent billed only while serving. Even though access is authed, caps prevent runaway spend.

---

## 16. Implementation sequencing

Deliver the thin slice in three internal steps so the voice loop is de-risked before auth/sync:

- **1a — Prove the loop (internal):** Worker (temporary unauthenticated token), agent on LiveKit Cloud, Swift client connects, entry context passed via metadata, coach greets referencing the entry, two-way audio works end-to-end.
- **1b — Supabase Google auth:** sign-in in the app; Worker verifies Supabase JWT; Voice gated behind sign-in.
- **1c — Persistence:** capture transcript; write locally (`VoiceSessions/...`) + upload to `voice_sessions` (RLS).

Ship v1 after 1c. Phases 2/3 (tools, summaries, RAG) are separate spec → plan cycles.

---

## 17. Testing strategy

- **Worker:** unit-test Supabase JWT verification (valid/expired/wrong-aud), LiveKit JWT structure (grants, room, metadata round-trip), context size-cap behavior.
- **Agent:** unit-test `build_system_prompt(context)` for text/video/empty/truncated cases; integration test reading `participant.metadata`.
- **Swift:** manual end-to-end (record? no — speak) checklist: sign-in, start on a text entry, start on a video entry, empty entry, mute, end, 20-min cap, mic-contention with video recorder, transcript saved locally + in Supabase, dark mode, permission-denied path, offline path.
- **Privacy check:** confirm no journal text in any analytics; confirm only voice-session data leaves device.

---

## 18. Open questions / risks

1. **Exact Jungle model stack** — confirm STT/TTS providers/versions + turn detection from `requirements.txt`/`agent.py` at implementation; match unless deliberately swapping (we swap LLM → Claude).
2. **Long-entry context** — v1 caps at ~6 KB; validate this feels acceptable, or prioritize the data-channel handshake sooner.
3. **Agent deploy specifics** — confirm `lk agent create` flow / `livekit.toml` for our project; how Jungle currently deploys its agent (for parity).
4. **Provider zero-retention** — verify Deepgram/Anthropic/Cartesia retention settings for a privacy-sensitive product.
5. **Reusing Jungle keys** — fine for dev; note the LiveKit project/room namespace is shared with Jungle until we provision our own.

## 19. Security note (out of scope, flagged)

Jungle's `wrangler.toml` currently has **live secrets committed in git** (Stripe `sk_live_…`, OpenAI key, GitHub `ghp_…`, AWS keys). Recommend rotating + moving to `wrangler secret put` + scrubbing history. Tracked separately from this feature.

---

## 20. Future (post-v1)

Coach tools (Phase 2/3 per §10.2), post-session summary/insight write-back (Cloudflare Worker → AI Gateway → Claude), RAG over past entries (pgvector), optional full journal cloud sync, analytics instrumentation (PostHog/Sentry per house standards), fresh API keys + dedicated LiveKit project.
