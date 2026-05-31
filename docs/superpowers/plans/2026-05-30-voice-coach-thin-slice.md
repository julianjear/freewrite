# Voice Coach (Thin Slice) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, chosen for the backend Parts) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the thin-slice Voice Coach: press "Voice" next to "Chat", authenticate (Supabase Google), have a spoken coaching conversation that already knows the current entry, and save the transcript locally + to Supabase.

**Architecture:** Swift client (LiveKit Swift SDK) → Cloudflare Worker mints a LiveKit JWT carrying the entry context in its `metadata` claim → LiveKit Cloud dispatches a Python coach agent (Deepgram STT → Gemini/Claude LLM → ElevenLabs TTS) → transcript saved locally and to Supabase. Spec: [2026-05-30-voice-coach-design.md](../specs/2026-05-30-voice-coach-design.md).

**Tech Stack:** Cloudflare Workers (TypeScript, `jose`, Web Crypto), Python 3.11 + `livekit-agents~=1.5`, Supabase (Auth + Postgres + RLS), SwiftUI + `client-sdk-swift` + `supabase-swift`.

---

## Execution boundary (read first)

This plan is sequenced so the parts that need **no external accounts** come first and are fully verified here; the parts that need **your accounts/secrets or a human voice** are spelled out but flagged.

| Part | What | Execution status |
|---|---|---|
| **A** | Cloudflare Worker: token endpoint (Supabase JWT verify + LiveKit JWT sign + context cap) | **Autonomous** — full TDD with vitest, offline. Built + tested + committed here. |
| **B** | Python coach agent: prompt/context pure logic (+ agent entrypoint written) | **Autonomous for the pure logic** (pytest, offline). The live `agent.py` is written but only *runs* with LiveKit creds (Part E). |
| **C** | Swift client: context model + capping (TDD), token client, manager, button, overlay | **Mixed** — Swift code written here; the Codable+capping unit is TDD-tested; **adding SPM packages + building requires your Xcode** (you have it open). |
| **D** | Supabase: project, Google OAuth, `voice_sessions` table + RLS | **Needs you** — account provisioning. Exact steps provided; SQL is ready to paste. |
| **E** | Deploy (Worker + agent to LiveKit Cloud) + secrets + end-to-end voice test | **Needs you** — accounts, secrets, and a human to talk. Exact commands + manual checklist provided. |

I execute **A** and **B (pure logic)** now. **C** code is written now; SPM/build is your click. **D/E** are your provisioning, with precise runbooks.

---

## File structure

```
backend/
  voice-token-worker/            # Part A (Cloudflare Worker)
    src/
      index.ts                   # fetch handler + routing + CORS
      auth.ts                    # verifySupabaseJWT (jose, HS256 shared secret)
      token.ts                   # signLiveKitToken (Web Crypto HS256)
      context.ts                 # types + capEntryText + buildRoomName + buildMetadata
      index.test.ts              # handler tests
      auth.test.ts
      token.test.ts
      context.test.ts
    package.json
    tsconfig.json
    vitest.config.ts
    wrangler.toml                # NO real secrets; secrets via `wrangler secret put`
    .dev.vars.example
    .gitignore
  voice-coach-agent/             # Part B (Python LiveKit agent)
    coach/
      __init__.py
      context.py                 # parse_context + cap_entry_text  (pure, no livekit import)
      prompt.py                  # COACH_PERSONA + build_system_prompt + build_opener (pure)
    agent.py                     # LiveKit entrypoint (imports livekit; run in Part E)
    tests/
      test_context.py
      test_prompt.py
    requirements.txt             # runtime (livekit-agents[...])
    requirements-dev.txt         # pytest
    livekit.toml                 # agent deploy config (Part E)
    .gitignore
    README.md
freewrite/
  Voice/                         # Part C (new Swift feature dir; isolated from ContentView)
    VoiceContext.swift           # Codable payload + cap logic (TDD)
    VoiceTokenClient.swift       # POST /voice/token
    VoiceSession.swift           # auth/session state model
    VoiceCoachManager.swift      # LiveKit Room lifecycle, agent-state, transcript capture
    VoiceTranscriptStore.swift   # local + Supabase persistence
    VoiceCoachOverlay.swift      # session UI
    VoiceWaveform.swift          # amplitude visualization
    SupabaseAuth.swift           # Google sign-in wrapper
  ContentView.swift              # MODIFY: add "Voice" button next to "Chat" (~line 1458)
  freewrite.entitlements         # MODIFY: add network.client
freewriteTests/
  VoiceContextTests.swift        # Part C TDD (capping/serialization)
```

---

# PART A — Cloudflare Worker (token endpoint) — AUTONOMOUS

**Why first:** zero external accounts, pure TDD, and it's the architectural lynchpin (everything else calls it).

**Testing note:** Node 22 has global `Request`/`Response`/`crypto.subtle`, and `jose` runs in node — so handlers are tested directly in vitest, offline. We verify Supabase JWTs as **HS256 shared-secret** (Supabase's legacy/symmetric mode — simplest, fully offline-testable). JWKS/asymmetric is a documented upgrade in §Notes.

### Task A1: Scaffold the Worker project

**Files:**
- Create: `backend/voice-token-worker/package.json`
- Create: `backend/voice-token-worker/tsconfig.json`
- Create: `backend/voice-token-worker/vitest.config.ts`
- Create: `backend/voice-token-worker/.gitignore`
- Create: `backend/voice-token-worker/.dev.vars.example`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "voice-token-worker",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "jose": "^5.9.6"
  },
  "devDependencies": {
    "typescript": "^5.6.3",
    "vitest": "^2.1.8",
    "wrangler": "^3.90.0",
    "@cloudflare/workers-types": "^4.20241127.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 3: Create `vitest.config.ts`**

```typescript
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
```

- [ ] **Step 4: Create `.gitignore`**

```
node_modules/
.wrangler/
.dev.vars
dist/
```

- [ ] **Step 5: Create `.dev.vars.example`** (documents required secrets; the real `.dev.vars` is git-ignored)

```
# Copy to .dev.vars and fill in. NEVER commit .dev.vars.
LIVEKIT_URL=wss://your-project.livekit.cloud
LIVEKIT_API_KEY=APIxxxxxxxx
LIVEKIT_API_SECRET=secretxxxxxxxx
SUPABASE_JWT_SECRET=your-supabase-jwt-secret
COACH_AGENT_NAME=freewrite-coach
ALLOWED_ORIGIN=*
```

- [ ] **Step 6: Install deps**

Run: `cd backend/voice-token-worker && npm install`
Expected: `node_modules/` created, `jose`/`vitest`/`wrangler` present. (If the sandbox blocks network, note it; the code+tests are still committed and you run `npm install` locally.)

- [ ] **Step 7: Commit**

```bash
git add backend/voice-token-worker/package.json backend/voice-token-worker/tsconfig.json backend/voice-token-worker/vitest.config.ts backend/voice-token-worker/.gitignore backend/voice-token-worker/.dev.vars.example
git commit -m "chore(worker): scaffold voice-token-worker"
```

---

### Task A2: `capEntryText` — bound the context size

**Files:**
- Create: `backend/voice-token-worker/src/context.ts`
- Test: `backend/voice-token-worker/src/context.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { describe, it, expect } from "vitest";
import { capEntryText, MAX_ENTRY_BYTES } from "./context";

describe("capEntryText", () => {
  it("returns short text unchanged and not truncated", () => {
    const r = capEntryText("hello world");
    expect(r.text).toBe("hello world");
    expect(r.truncated).toBe(false);
  });

  it("keeps the most recent bytes when over the cap and marks truncated", () => {
    const long = "x".repeat(MAX_ENTRY_BYTES + 500) + "TAIL";
    const r = capEntryText(long);
    expect(r.truncated).toBe(true);
    expect(r.text.endsWith("TAIL")).toBe(true);
    expect(Buffer.byteLength(r.text, "utf8")).toBeLessThanOrEqual(MAX_ENTRY_BYTES);
  });

  it("handles null/undefined as empty, not truncated", () => {
    expect(capEntryText(undefined).text).toBe("");
    expect(capEntryText(null).truncated).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/voice-token-worker && npx vitest run src/context.test.ts`
Expected: FAIL — cannot find module `./context`.

- [ ] **Step 3: Write minimal implementation**

```typescript
// backend/voice-token-worker/src/context.ts

// Cap embedded entry text so the signed JWT (and the HTTP header carrying it)
// stays well under practical limits. Recent writing is the most relevant, so
// we keep the TAIL of the text. ~6 KB leaves headroom for the rest of the JWT.
export const MAX_ENTRY_BYTES = 6144;

export interface CapResult {
  text: string;
  truncated: boolean;
}

export function capEntryText(input: string | null | undefined): CapResult {
  const text = input ?? "";
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes <= MAX_ENTRY_BYTES) return { text, truncated: false };

  // Keep the last MAX_ENTRY_BYTES bytes, then repair any split UTF-8 char.
  const buf = Buffer.from(text, "utf8");
  let start = buf.length - MAX_ENTRY_BYTES;
  // Advance start past continuation bytes (0b10xxxxxx) to a char boundary.
  while (start < buf.length && (buf[start] & 0xc0) === 0x80) start++;
  return { text: buf.toString("utf8", start), truncated: true };
}
```

> Note: `Buffer` is for offline node tests. The Worker runtime also has `Buffer` available with `nodejs_compat` (set in `wrangler.toml`, Task A6). If you prefer a runtime-pure version, swap to `TextEncoder`/`TextDecoder`; tests stay valid.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/voice-token-worker && npx vitest run src/context.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/voice-token-worker/src/context.ts backend/voice-token-worker/src/context.test.ts
git commit -m "feat(worker): capEntryText bounds context to most-recent 6KB"
```

---

### Task A3: `buildRoomName` + `buildMetadata`

**Files:**
- Modify: `backend/voice-token-worker/src/context.ts`
- Modify: `backend/voice-token-worker/src/context.test.ts`

- [ ] **Step 1: Add failing tests**

```typescript
// append to context.test.ts
import { buildRoomName, buildMetadata } from "./context";

describe("buildRoomName", () => {
  it("uses userId + entryId + timestamp", () => {
    const name = buildRoomName("user-abc", "entry-123", 1700000000000);
    expect(name).toBe("freewrite-user-abc-entry-123-1700000000000");
  });
  it("uses 'transient' when no entryId", () => {
    const name = buildRoomName("user-abc", null, 1700000000000);
    expect(name).toBe("freewrite-user-abc-transient-1700000000000");
  });
});

describe("buildMetadata", () => {
  it("nests context under a context key and stamps userId", () => {
    const meta = buildMetadata("user-abc", {
      entryType: "text",
      entryDate: "May 30",
      entryText: "hi",
      hasTranscript: true,
      truncated: false,
      modality: "voice",
    });
    const parsed = JSON.parse(meta);
    expect(parsed.userId).toBe("user-abc");
    expect(parsed.context.entryType).toBe("text");
    expect(parsed.context.entryText).toBe("hi");
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-token-worker && npx vitest run src/context.test.ts`
Expected: FAIL — `buildRoomName`/`buildMetadata` not exported.

- [ ] **Step 3: Implement**

```typescript
// append to context.ts

export interface VoiceContext {
  entryType: "text" | "video";
  entryDate: string;
  entryText: string;
  hasTranscript: boolean;
  truncated: boolean;
  modality: "voice";
}

export function buildRoomName(
  userId: string,
  entryId: string | null,
  nowMs: number,
): string {
  const mid = entryId ?? "transient";
  return `freewrite-${userId}-${mid}-${nowMs}`;
}

export function buildMetadata(userId: string, context: VoiceContext): string {
  return JSON.stringify({ userId, context });
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-token-worker && npx vitest run src/context.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/voice-token-worker/src/context.ts backend/voice-token-worker/src/context.test.ts
git commit -m "feat(worker): room-name + metadata builders"
```

---

### Task A4: `signLiveKitToken` (Web Crypto HS256)

**Files:**
- Create: `backend/voice-token-worker/src/token.ts`
- Test: `backend/voice-token-worker/src/token.test.ts`

- [ ] **Step 1: Write the failing test** (sign, then verify the JWT with `jose` and assert claims)

```typescript
import { describe, it, expect } from "vitest";
import { jwtVerify } from "jose";
import { signLiveKitToken } from "./token";

const KEY = "APItestkey";
const SECRET = "supersecretvalue-supersecretvalue";

describe("signLiveKitToken", () => {
  it("produces a JWT with LiveKit grants, room, metadata, and agent dispatch", async () => {
    const jwt = await signLiveKitToken({
      apiKey: KEY,
      apiSecret: SECRET,
      identity: "user-abc",
      roomName: "freewrite-user-abc-entry-1-1700000000000",
      metadata: JSON.stringify({ userId: "user-abc" }),
      agentName: "freewrite-coach",
      ttlSeconds: 1200,
      nowMs: 1700000000000,
    });
    const { payload } = await jwtVerify(jwt, new TextEncoder().encode(SECRET));
    expect(payload.iss).toBe(KEY);
    expect(payload.sub).toBe("user-abc");
    const video = payload.video as Record<string, unknown>;
    expect(video.room).toBe("freewrite-user-abc-entry-1-1700000000000");
    expect(video.roomJoin).toBe(true);
    expect(video.canPublish).toBe(true);
    expect(video.canSubscribe).toBe(true);
    expect(payload.metadata).toBe(JSON.stringify({ userId: "user-abc" }));
    const roomConfig = payload.roomConfig as Record<string, any>;
    expect(roomConfig.agents[0].agentName).toBe("freewrite-coach");
    expect(payload.exp).toBe(1700000000 + 1200);
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-token-worker && npx vitest run src/token.test.ts`
Expected: FAIL — cannot find `./token`.

- [ ] **Step 3: Implement** (mirrors Jungle `livekit-routes.ts:760-809`, simplified)

```typescript
// backend/voice-token-worker/src/token.ts

export interface SignArgs {
  apiKey: string;
  apiSecret: string;
  identity: string;
  roomName: string;
  metadata: string;
  agentName: string;
  ttlSeconds: number;
  nowMs: number;
}

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlJSON(obj: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(obj)));
}

export async function signLiveKitToken(a: SignArgs): Promise<string> {
  const now = Math.floor(a.nowMs / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    iss: a.apiKey,
    sub: a.identity,
    iat: now,
    nbf: now,
    exp: now + a.ttlSeconds,
    video: {
      room: a.roomName,
      roomJoin: true,
      canPublish: true,
      canPublishData: true,
      canSubscribe: true,
      canUpdateOwnMetadata: true,
    },
    metadata: a.metadata,
    roomConfig: { agents: [{ agentName: a.agentName }] },
  };
  const signingInput = `${b64urlJSON(header)}.${b64urlJSON(payload)}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(a.apiSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-token-worker && npx vitest run src/token.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/voice-token-worker/src/token.ts backend/voice-token-worker/src/token.test.ts
git commit -m "feat(worker): sign LiveKit JWT via Web Crypto HS256"
```

---

### Task A5: `verifySupabaseJWT` (jose, HS256)

**Files:**
- Create: `backend/voice-token-worker/src/auth.ts`
- Test: `backend/voice-token-worker/src/auth.test.ts`

- [ ] **Step 1: Write the failing test** (sign a Supabase-shaped token with `jose`, assert verify returns the user; assert rejects expired + wrong-secret)

```typescript
import { describe, it, expect } from "vitest";
import { SignJWT } from "jose";
import { verifySupabaseJWT } from "./auth";

const SECRET = "supabase-test-jwt-secret-supabase";
const enc = new TextEncoder();

async function makeToken(opts: { sub?: string; expOffset?: number; secret?: string }) {
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({ role: "authenticated", email: "a@b.com" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(opts.sub ?? "user-abc")
    .setIssuedAt(now)
    .setExpirationTime(now + (opts.expOffset ?? 3600))
    .sign(enc.encode(opts.secret ?? SECRET));
}

describe("verifySupabaseJWT", () => {
  it("returns userId + email for a valid token", async () => {
    const token = await makeToken({ sub: "user-abc" });
    const r = await verifySupabaseJWT(token, SECRET);
    expect(r.userId).toBe("user-abc");
    expect(r.email).toBe("a@b.com");
  });

  it("throws on expired token", async () => {
    const token = await makeToken({ expOffset: -10 });
    await expect(verifySupabaseJWT(token, SECRET)).rejects.toThrow();
  });

  it("throws on wrong secret", async () => {
    const token = await makeToken({ secret: "the-wrong-secret-the-wrong-secret" });
    await expect(verifySupabaseJWT(token, SECRET)).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-token-worker && npx vitest run src/auth.test.ts`
Expected: FAIL — cannot find `./auth`.

- [ ] **Step 3: Implement**

```typescript
// backend/voice-token-worker/src/auth.ts
import { jwtVerify } from "jose";

export interface AuthedUser {
  userId: string;
  email: string | null;
}

// Verifies a Supabase access token (HS256, signed with the project JWT secret).
// jwtVerify enforces signature + exp. Supabase tokens carry the user id in `sub`.
export async function verifySupabaseJWT(
  token: string,
  jwtSecret: string,
): Promise<AuthedUser> {
  const { payload } = await jwtVerify(token, new TextEncoder().encode(jwtSecret));
  const userId = typeof payload.sub === "string" ? payload.sub : "";
  if (!userId) throw new Error("token has no subject");
  const email = typeof payload.email === "string" ? payload.email : null;
  return { userId, email };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-token-worker && npx vitest run src/auth.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/voice-token-worker/src/auth.ts backend/voice-token-worker/src/auth.test.ts
git commit -m "feat(worker): verify Supabase HS256 access tokens"
```

---

### Task A6: `wrangler.toml`

**Files:**
- Create: `backend/voice-token-worker/wrangler.toml`

- [ ] **Step 1: Create config** (no secrets here — those go via `wrangler secret put` in Part E)

```toml
name = "freewrite-voice-token"
main = "src/index.ts"
compatibility_date = "2024-11-27"
compatibility_flags = ["nodejs_compat"]

# Secrets (set with `wrangler secret put <NAME>` — never commit):
#   LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, SUPABASE_JWT_SECRET
[vars]
COACH_AGENT_NAME = "freewrite-coach"
ALLOWED_ORIGIN = "*"
TOKEN_TTL_SECONDS = "1200"
```

- [ ] **Step 2: Commit**

```bash
git add backend/voice-token-worker/wrangler.toml
git commit -m "chore(worker): wrangler config (secrets excluded)"
```

---

### Task A7: `index.ts` handler — wire it all together

**Files:**
- Create: `backend/voice-token-worker/src/index.ts`
- Test: `backend/voice-token-worker/src/index.test.ts`

- [ ] **Step 1: Write the failing tests** (construct `Request` + fake `env`, call `handleToken`)

```typescript
import { describe, it, expect } from "vitest";
import { SignJWT, jwtVerify } from "jose";
import { handleToken, type Env } from "./index";

const enc = new TextEncoder();
const env: Env = {
  LIVEKIT_URL: "wss://test.livekit.cloud",
  LIVEKIT_API_KEY: "APItestkey",
  LIVEKIT_API_SECRET: "supersecretvalue-supersecretvalue",
  SUPABASE_JWT_SECRET: "supabase-test-jwt-secret-supabase",
  COACH_AGENT_NAME: "freewrite-coach",
  ALLOWED_ORIGIN: "*",
  TOKEN_TTL_SECONDS: "1200",
};

async function userToken() {
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({ email: "a@b.com" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject("user-abc")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(enc.encode(env.SUPABASE_JWT_SECRET));
}

function req(body: unknown, auth?: string) {
  return new Request("https://w/voice/token", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(auth ? { authorization: `Bearer ${auth}` } : {}),
    },
    body: JSON.stringify(body),
  });
}

describe("handleToken", () => {
  it("401 without auth", async () => {
    const res = await handleToken(req({ context: {} }), env);
    expect(res.status).toBe(401);
  });

  it("200 returns token+wsUrl+sessionId; token carries capped context in metadata", async () => {
    const ctx = {
      entryType: "text",
      entryDate: "May 30",
      entryText: "I keep avoiding the hard conversation.",
      hasTranscript: false,
      modality: "voice",
    };
    const res = await handleToken(req({ context: ctx, entryId: "entry-1" }, await userToken()), env);
    expect(res.status).toBe(200);
    const json = await res.json() as any;
    expect(json.wsUrl).toBe(env.LIVEKIT_URL);
    expect(json.sessionId).toMatch(/^freewrite-user-abc-entry-1-\d+$/);
    const { payload } = await jwtVerify(json.token, enc.encode(env.LIVEKIT_API_SECRET));
    const meta = JSON.parse(payload.metadata as string);
    expect(meta.userId).toBe("user-abc");
    expect(meta.context.entryText).toContain("hard conversation");
    expect(meta.context.truncated).toBe(false);
  });

  it("400 on malformed JSON body", async () => {
    const bad = new Request("https://w/voice/token", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${await userToken()}` },
      body: "{not json",
    });
    const res = await handleToken(bad, env);
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-token-worker && npx vitest run src/index.test.ts`
Expected: FAIL — cannot find `./index` exports.

- [ ] **Step 3: Implement**

```typescript
// backend/voice-token-worker/src/index.ts
import { verifySupabaseJWT } from "./auth";
import { signLiveKitToken } from "./token";
import {
  capEntryText,
  buildRoomName,
  buildMetadata,
  type VoiceContext,
} from "./context";

export interface Env {
  LIVEKIT_URL: string;
  LIVEKIT_API_KEY: string;
  LIVEKIT_API_SECRET: string;
  SUPABASE_JWT_SECRET: string;
  COACH_AGENT_NAME: string;
  ALLOWED_ORIGIN: string;
  TOKEN_TTL_SECONDS: string;
}

function cors(env: Env): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN || "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type",
  };
}

function json(body: unknown, status: number, env: Env): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...cors(env) },
  });
}

export async function handleToken(request: Request, env: Env): Promise<Response> {
  // Auth
  const authHeader = request.headers.get("authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "missing bearer token" }, 401, env);
  }
  let user;
  try {
    user = await verifySupabaseJWT(authHeader.slice(7).trim(), env.SUPABASE_JWT_SECRET);
  } catch {
    return json({ error: "invalid token" }, 401, env);
  }

  // Body
  let body: any;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid json" }, 400, env);
  }

  const raw = (body?.context ?? {}) as Record<string, unknown>;
  const capped = capEntryText(typeof raw.entryText === "string" ? raw.entryText : "");
  const context: VoiceContext = {
    entryType: raw.entryType === "video" ? "video" : "text",
    entryDate: typeof raw.entryDate === "string" ? raw.entryDate : "",
    entryText: capped.text,
    hasTranscript: raw.hasTranscript === true,
    truncated: capped.truncated,
    modality: "voice",
  };

  const entryId = typeof body?.entryId === "string" ? body.entryId : null;
  const nowMs = Date.now();
  const roomName = buildRoomName(user.userId, entryId, nowMs);
  const metadata = buildMetadata(user.userId, context);

  const token = await signLiveKitToken({
    apiKey: env.LIVEKIT_API_KEY,
    apiSecret: env.LIVEKIT_API_SECRET,
    identity: user.userId,
    roomName,
    metadata,
    agentName: env.COACH_AGENT_NAME,
    ttlSeconds: parseInt(env.TOKEN_TTL_SECONDS || "1200", 10),
    nowMs,
  });

  return json({ token, wsUrl: env.LIVEKIT_URL, sessionId: roomName }, 200, env);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors(env) });
    }
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/voice/token") {
      return handleToken(request, env);
    }
    return json({ error: "not found" }, 404, env);
  },
};
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-token-worker && npx vitest run src/index.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite**

Run: `cd backend/voice-token-worker && npx vitest run`
Expected: PASS — all files (context, token, auth, index) green.

- [ ] **Step 6: Commit**

```bash
git add backend/voice-token-worker/src/index.ts backend/voice-token-worker/src/index.test.ts
git commit -m "feat(worker): /voice/token handler (auth + cap + sign)"
```

---

# PART B — Python coach agent — AUTONOMOUS (pure logic) + written entrypoint

**Separation:** `coach/` is **pure Python, no livekit import**, so its tests run in a tiny venv offline. `agent.py` is the only file importing `livekit` and is *run* in Part E. We mirror Jungle's read pattern: `meta = json.loads(participant.metadata); context = meta["context"]; system_prompt = build_system_prompt(...)`.

### Task B1: Scaffold the agent project + venv

**Files:**
- Create: `backend/voice-coach-agent/coach/__init__.py` (empty)
- Create: `backend/voice-coach-agent/requirements.txt`
- Create: `backend/voice-coach-agent/requirements-dev.txt`
- Create: `backend/voice-coach-agent/.gitignore`

- [ ] **Step 1: Create `coach/__init__.py`** (empty file)

- [ ] **Step 2: Create `requirements.txt`** (mirrors Jungle's stack; LLM provider per spec §5.4)

```
# LiveKit Agents voice stack (mirrors Jungle).
livekit-agents[deepgram,elevenlabs,google,silero,turn-detector]~=1.5.13
google-genai>=1.55,<3
python-dotenv>=1.0.0
```

- [ ] **Step 3: Create `requirements-dev.txt`**

```
pytest>=8.0
```

- [ ] **Step 4: Create `.gitignore`**

```
.venv/
__pycache__/
*.pyc
.env
```

- [ ] **Step 5: Create the test venv and install pytest**

Run:
```bash
cd backend/voice-coach-agent && python3 -m venv .venv && ./.venv/bin/pip install -q -r requirements-dev.txt && ./.venv/bin/python -c "import pytest; print('pytest', pytest.__version__)"
```
Expected: prints `pytest 8.x`. (If network is blocked, note it; tests still committed, you run this locally. Fallback: `pyenv activate myenv5 && pip install pytest`.)

- [ ] **Step 6: Commit**

```bash
git add backend/voice-coach-agent/coach/__init__.py backend/voice-coach-agent/requirements.txt backend/voice-coach-agent/requirements-dev.txt backend/voice-coach-agent/.gitignore
git commit -m "chore(agent): scaffold voice-coach-agent + dev deps"
```

---

### Task B2: `parse_context` + `cap_entry_text`

**Files:**
- Create: `backend/voice-coach-agent/coach/context.py`
- Create: `backend/voice-coach-agent/tests/test_context.py`

- [ ] **Step 1: Write the failing test**

```python
# backend/voice-coach-agent/tests/test_context.py
import json
from coach.context import parse_context, cap_entry_text, MAX_ENTRY_CHARS, CoachContext


def test_parse_valid_metadata():
    meta = json.dumps({
        "userId": "user-abc",
        "context": {
            "entryType": "text",
            "entryDate": "May 30",
            "entryText": "I keep avoiding it.",
            "hasTranscript": False,
            "truncated": False,
            "modality": "voice",
        },
    })
    ctx = parse_context(meta)
    assert isinstance(ctx, CoachContext)
    assert ctx.entry_type == "text"
    assert ctx.entry_text == "I keep avoiding it."
    assert ctx.entry_date == "May 30"


def test_parse_missing_or_bad_metadata_returns_empty():
    assert parse_context(None).entry_text == ""
    assert parse_context("{not json").entry_text == ""
    assert parse_context("{}").entry_type == "text"


def test_cap_entry_text_keeps_tail():
    long = "a" * (MAX_ENTRY_CHARS + 50) + "TAIL"
    capped, truncated = cap_entry_text(long)
    assert truncated is True
    assert capped.endswith("TAIL")
    assert len(capped) <= MAX_ENTRY_CHARS
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-coach-agent && ./.venv/bin/python -m pytest tests/test_context.py -v`
Expected: FAIL — cannot import `coach.context`.

- [ ] **Step 3: Implement**

```python
# backend/voice-coach-agent/coach/context.py
"""Pure context parsing — no livekit import, so it unit-tests offline.

Mirrors Jungle's `meta = json.loads(participant.metadata); meta["context"]`.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

# A second safety net behind the Worker's byte cap (the Worker already caps to
# ~6 KB; this guards against any oversized text reaching the prompt builder).
MAX_ENTRY_CHARS = 6000


@dataclass
class CoachContext:
    entry_type: str = "text"
    entry_date: str = ""
    entry_text: str = ""
    has_transcript: bool = False
    truncated: bool = False


def cap_entry_text(text: str) -> tuple[str, bool]:
    if text is None:
        return "", False
    if len(text) <= MAX_ENTRY_CHARS:
        return text, False
    return text[-MAX_ENTRY_CHARS:], True


def parse_context(metadata: str | None) -> CoachContext:
    if not metadata:
        return CoachContext()
    try:
        meta = json.loads(metadata)
    except (json.JSONDecodeError, TypeError):
        return CoachContext()
    ctx = meta.get("context") or {}
    text, truncated = cap_entry_text(str(ctx.get("entryText") or ""))
    return CoachContext(
        entry_type="video" if ctx.get("entryType") == "video" else "text",
        entry_date=str(ctx.get("entryDate") or ""),
        entry_text=text,
        has_transcript=bool(ctx.get("hasTranscript")),
        truncated=bool(ctx.get("truncated")) or truncated,
    )
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-coach-agent && ./.venv/bin/python -m pytest tests/test_context.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/voice-coach-agent/coach/context.py backend/voice-coach-agent/tests/test_context.py
git commit -m "feat(agent): parse + cap per-session context (pure)"
```

---

### Task B3: `build_system_prompt` + `build_opener`

**Files:**
- Create: `backend/voice-coach-agent/coach/prompt.py`
- Create: `backend/voice-coach-agent/tests/test_prompt.py`

> The persona prose here is a **working placeholder** Julian will refine (spec §10.1). The tests assert *structure/behavior* (context is injected; empty vs filled vs truncated branches differ), not the exact wording — so refining the prose later won't break tests.

- [ ] **Step 1: Write the failing test**

```python
# backend/voice-coach-agent/tests/test_prompt.py
from coach.context import CoachContext
from coach.prompt import build_system_prompt, build_opener, COACH_PERSONA


def test_system_prompt_includes_persona_and_entry_text():
    ctx = CoachContext(entry_type="text", entry_date="May 30",
                        entry_text="I keep avoiding the hard conversation.")
    p = build_system_prompt(ctx)
    assert COACH_PERSONA.strip()[:20] in p
    assert "hard conversation" in p
    assert "May 30" in p


def test_system_prompt_handles_empty_entry():
    p = build_system_prompt(CoachContext(entry_text=""))
    assert "haven't written" in p.lower() or "nothing written" in p.lower()


def test_system_prompt_notes_truncation():
    ctx = CoachContext(entry_text="partial...", truncated=True)
    assert "portion" in build_system_prompt(ctx).lower()


def test_opener_references_writing_when_present():
    ctx = CoachContext(entry_text="I keep avoiding it.")
    assert "?" in build_opener(ctx)  # opens with a question

def test_opener_is_open_ended_when_empty():
    assert "?" in build_opener(CoachContext(entry_text=""))
```

- [ ] **Step 2: Run to verify fail**

Run: `cd backend/voice-coach-agent && ./.venv/bin/python -m pytest tests/test_prompt.py -v`
Expected: FAIL — cannot import `coach.prompt`.

- [ ] **Step 3: Implement** (placeholder coach persona — refine prose later)

```python
# backend/voice-coach-agent/coach/prompt.py
"""Coach persona + prompt builder (pure). Refine COACH_PERSONA prose freely;
tests assert behavior (context injection, branch differences), not wording.
"""
from __future__ import annotations

from coach.context import CoachContext

COACH_PERSONA = """\
You are a warm, perceptive personal coach having a spoken conversation. Your
purpose is to help the writer find clarity about who they are and what matters
to them. You are not a tutor and not a therapist. You listen more than you talk.
You ask one open, specific question at a time. You reflect the writer's own
words back to them. You help them go one layer deeper rather than giving advice.
Keep replies short and conversational — this is voice, not an essay.
"""

_FRAME = """\
Coaching frame:
- Lead with curiosity. Ask, don't lecture.
- One question at a time. Leave room for silence.
- Mirror their language; don't reframe in your words unless asked.
- Go for depth and clarity, not solutions.
- It's a voice call: keep turns short and natural.
"""


def build_system_prompt(ctx: CoachContext) -> str:
    parts = [COACH_PERSONA, _FRAME]
    if ctx.entry_text.strip():
        kind = "video reflection" if ctx.entry_type == "video" else "journal entry"
        when = f" (dated {ctx.entry_date})" if ctx.entry_date else ""
        parts.append(f"Here is what the writer just wrote in their {kind}{when}:\n\n{ctx.entry_text}")
        if ctx.truncated:
            parts.append("(You are seeing only the most recent portion of a longer entry.)")
    else:
        parts.append(
            "The writer hasn't written anything yet for this session "
            "(nothing written). Open the conversation gently and let them lead."
        )
    return "\n\n".join(parts)


def build_opener(ctx: CoachContext) -> str:
    if ctx.entry_text.strip():
        return "I just read what you wrote. What feels most alive in it for you right now?"
    return "Hey — what's on your mind right now?"
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend/voice-coach-agent && ./.venv/bin/python -m pytest tests/test_prompt.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full agent suite**

Run: `cd backend/voice-coach-agent && ./.venv/bin/python -m pytest -v`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/voice-coach-agent/coach/prompt.py backend/voice-coach-agent/tests/test_prompt.py
git commit -m "feat(agent): coach system prompt + opener (placeholder persona)"
```

---

### Task B4: `agent.py` entrypoint (written; run in Part E)

**Files:**
- Create: `backend/voice-coach-agent/agent.py`
- Create: `backend/voice-coach-agent/livekit.toml`
- Create: `backend/voice-coach-agent/README.md`

> Not unit-tested (needs LiveKit creds + audio). It's thin glue over the tested `coach/` package, mirroring Jungle `agent.py:709-895`. The LLM line implements spec §5.4 **default = Option 2 (Gemini via Cloudflare AI Gateway)** with a one-line switch documented inline.

- [ ] **Step 1: Write `agent.py`**

```python
# backend/voice-coach-agent/agent.py
"""Freewrite Voice Coach — LiveKit agent entrypoint.

Thin glue over the unit-tested `coach/` package. Mirrors Jungle's read pattern:
reads the per-session context the Cloudflare Worker put in the JWT metadata,
builds the coach system prompt, and runs the Deepgram->LLM->ElevenLabs loop.
"""
from __future__ import annotations

import logging
import os

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import Agent, AgentSession, JobContext, WorkerOptions
from livekit.plugins import deepgram, elevenlabs, silero
from livekit.plugins.turn_detector.multilingual import MultilingualModel

from coach.context import parse_context
from coach.prompt import build_system_prompt, build_opener

load_dotenv()
logger = logging.getLogger("freewrite-coach")

AGENT_NAME = os.environ.get("COACH_AGENT_NAME", "freewrite-coach")


def _build_llm():
    """Spec §5.4. DEFAULT = Option 2: Gemini via Cloudflare AI Gateway
    (OpenAI-compatible base_url) so voice LLM spend is observable in Cloudflare.

    Switch options by editing this function only:
      • Option 1 (native Gemini):   from livekit.plugins import google
                                     return google.LLM(model=os.environ["GEMINI_MODEL"])
      • Option 3 (Claude via CF):    model="anthropic/claude-...."
    """
    from livekit.plugins import openai
    return openai.LLM(
        model=os.environ.get("COACH_LLM_MODEL", "google-ai-studio/gemini-2.5-flash"),
        base_url=os.environ["CF_AI_GATEWAY_URL"],   # .../v1/<acct>/<gateway>/compat
        api_key=os.environ["CF_AI_GATEWAY_KEY"],
    )


async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    participant = await ctx.wait_for_participant()

    coach_ctx = parse_context(participant.metadata)
    system_prompt = build_system_prompt(coach_ctx)
    opener = build_opener(coach_ctx)
    logger.info("coach session room=%s entry_type=%s has_text=%s",
                ctx.room.name, coach_ctx.entry_type, bool(coach_ctx.entry_text))

    session = AgentSession(
        stt=deepgram.STT(model="nova-3", language="multi"),
        llm=_build_llm(),
        tts=elevenlabs.TTS(),
        vad=silero.VAD.load(),
        turn_detection=MultilingualModel(),
    )

    await session.start(agent=Agent(instructions=system_prompt), room=ctx.room)
    await session.generate_reply(instructions=f"Greet the writer. Say exactly: {opener}")


def _request_fnc(req: agents.JobRequest):
    # Only serve rooms we minted (defensive, mirrors Jungle).
    if req.room and req.room.name and req.room.name.startswith("freewrite-"):
        return req.accept(name=AGENT_NAME)
    return req.reject()


if __name__ == "__main__":
    agents.cli.run_app(
        WorkerOptions(entrypoint_fnc=entrypoint, agent_name=AGENT_NAME, request_fnc=_request_fnc)
    )
```

> ⚠️ **Verify-at-runtime (Part E):** `livekit-agents` 1.5 import paths (`livekit.plugins.turn_detector.multilingual`, `openai.LLM(base_url=...)`, `WorkerOptions` field names) must be checked against the actually-installed version — pin/adjust to match Jungle's working `agent.py` if any import differs. This is glue, not logic; the logic is the tested `coach/` package.

- [ ] **Step 2: Write `livekit.toml`** (filled during `lk agent create` in Part E; placeholder)

```toml
[project]
  subdomain = "REPLACE_WITH_YOUR_LIVEKIT_SUBDOMAIN"

[agent]
  id = "freewrite-coach"
```

- [ ] **Step 3: Write `README.md`** (run/deploy notes)

```markdown
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
```

- [ ] **Step 4: Commit**

```bash
git add backend/voice-coach-agent/agent.py backend/voice-coach-agent/livekit.toml backend/voice-coach-agent/README.md
git commit -m "feat(agent): LiveKit entrypoint over tested coach package"
```

---

# PART C — Swift client — code written here; SPM/build is yours

**Reality:** I write all Swift files now. The **Codable context + capping** unit is TDD'd against the existing `freewriteTests` target. But **adding the LiveKit + Supabase SPM packages and building** must happen in the Xcode you have open (hand-editing `project.pbxproj` for SPM is fragile and would fight your open Xcode). After you add the two packages (Task C0), the written code compiles.

### Task C0: Add SPM packages + entitlement (YOUR click, exact steps)

- [ ] **Step 1:** In Xcode (open on this worktree): File ▸ Add Package Dependencies → `https://github.com/livekit/client-sdk-swift` → Up to Next Major `2.5.0` → add **LiveKit** to the `freewrite` target.
- [ ] **Step 2:** Repeat: `https://github.com/supabase/supabase-swift` → add **Supabase** to the `freewrite` target.
- [ ] **Step 3:** Add the network-client entitlement (Task C1 edits the file; confirm Xcode picks it up).
- [ ] **Step 4:** Build (⌘B) once to resolve packages. Expected: builds clean (no code uses the SDKs yet until later tasks).

### Task C1: Add `network.client` entitlement

**Files:**
- Modify: `freewrite/freewrite.entitlements`

- [ ] **Step 1: Add the key** (after `audio-input`, before `</dict>`)

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

- [ ] **Step 2: Commit**

```bash
git add freewrite/freewrite.entitlements
git commit -m "feat(app): add network.client entitlement for voice"
```

### Task C2: `VoiceContext` Codable + capping (TDD)

**Files:**
- Create: `freewrite/Voice/VoiceContext.swift`
- Test: `freewriteTests/VoiceContextTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import freewrite

final class VoiceContextTests: XCTestCase {
    func testShortTextNotTruncated() {
        let c = VoiceContext.make(entryType: .text, entryDate: "May 30",
                                  entryText: "hello", hasTranscript: false)
        XCTAssertEqual(c.entryText, "hello")
        XCTAssertFalse(c.truncated)
    }

    func testLongTextKeepsTailAndMarksTruncated() {
        let long = String(repeating: "x", count: VoiceContext.maxEntryBytes + 500) + "TAIL"
        let c = VoiceContext.make(entryType: .text, entryDate: "May 30",
                                  entryText: long, hasTranscript: false)
        XCTAssertTrue(c.truncated)
        XCTAssertTrue(c.entryText.hasSuffix("TAIL"))
        XCTAssertLessThanOrEqual(c.entryText.utf8.count, VoiceContext.maxEntryBytes)
    }

    func testEncodesToExpectedJSONKeys() throws {
        let c = VoiceContext.make(entryType: .video, entryDate: "May 30",
                                  entryText: "hi", hasTranscript: true)
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["entryType"] as? String, "video")
        XCTAssertEqual(obj["modality"] as? String, "voice")
        XCTAssertEqual(obj["hasTranscript"] as? Bool, true)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `xcodebuild test -project freewrite.xcodeproj -scheme freewrite -destination 'platform=macOS' -only-testing:freewriteTests/VoiceContextTests`
Expected: FAIL — `VoiceContext` undefined.

- [ ] **Step 3: Implement**

```swift
// freewrite/Voice/VoiceContext.swift
import Foundation

struct VoiceContext: Codable {
    enum EntryKind: String, Codable { case text, video }

    let entryType: EntryKind
    let entryDate: String
    let entryText: String
    let hasTranscript: Bool
    let truncated: Bool
    let modality: String   // always "voice"

    static let maxEntryBytes = 6144

    static func make(entryType: EntryKind, entryDate: String,
                     entryText: String, hasTranscript: Bool) -> VoiceContext {
        let (capped, truncated) = capTail(entryText, maxBytes: maxEntryBytes)
        return VoiceContext(entryType: entryType, entryDate: entryDate,
                            entryText: capped, hasTranscript: hasTranscript,
                            truncated: truncated, modality: "voice")
    }

    /// Keep the most-recent `maxBytes` UTF-8 bytes, repaired to a char boundary.
    static func capTail(_ text: String, maxBytes: Int) -> (String, Bool) {
        let bytes = Array(text.utf8)
        if bytes.count <= maxBytes { return (text, false) }
        var start = bytes.count - maxBytes
        while start < bytes.count && (bytes[start] & 0xC0) == 0x80 { start += 1 }
        let slice = Array(bytes[start...])
        return (String(decoding: slice, as: UTF8.self), true)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -project freewrite.xcodeproj -scheme freewrite -destination 'platform=macOS' -only-testing:freewriteTests/VoiceContextTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add freewrite/Voice/VoiceContext.swift freewriteTests/VoiceContextTests.swift
git commit -m "feat(app): VoiceContext payload + tail-capping (TDD)"
```

### Task C3: `SupabaseAuth.swift` (Google sign-in wrapper)

**Files:**
- Create: `freewrite/Voice/SupabaseAuth.swift`

- [ ] **Step 1: Implement** (no unit test — wraps the SDK + system browser; verified live in Part E)

```swift
// freewrite/Voice/SupabaseAuth.swift
import Foundation
import Supabase

@MainActor
final class SupabaseAuth: ObservableObject {
    static let shared = SupabaseAuth()

    // Set from your Supabase project (anon key is publishable).
    private let client = SupabaseClient(
        supabaseURL: URL(string: "https://YOUR-PROJECT.supabase.co")!,
        supabaseKey: "YOUR-ANON-KEY"
    )

    @Published var accessToken: String?
    @Published var isSignedIn = false

    func restore() async {
        if let session = try? await client.auth.session {
            accessToken = session.accessToken
            isSignedIn = true
        }
    }

    /// Opens Google OAuth in the system browser; redirect scheme freewrite://auth-callback
    func signInWithGoogle() async throws {
        let session = try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: URL(string: "freewrite://auth-callback")!
        )
        accessToken = session.accessToken
        isSignedIn = true
    }

    func handleCallback(url: URL) async {
        try? await client.auth.session(from: url)
        if let session = try? await client.auth.session {
            accessToken = session.accessToken
            isSignedIn = true
        }
    }

    func currentToken() -> String? { accessToken }
}
```

> ⚠️ Part E: confirm `supabase-swift`'s exact OAuth API (`signInWithOAuth` vs `getOAuthSignInURL` + `ASWebAuthenticationSession`) against the installed version; adjust this wrapper to match. The URL-callback wiring goes in `freewriteApp.swift` via `.onOpenURL`.

- [ ] **Step 2: Commit**

```bash
git add freewrite/Voice/SupabaseAuth.swift
git commit -m "feat(app): Supabase Google sign-in wrapper"
```

### Task C4: `VoiceTokenClient.swift`

**Files:**
- Create: `freewrite/Voice/VoiceTokenClient.swift`

- [ ] **Step 1: Implement**

```swift
// freewrite/Voice/VoiceTokenClient.swift
import Foundation

struct VoiceSessionToken {
    let token: String
    let wsURL: URL
    let sessionId: String
}

enum VoiceTokenError: Error { case notAuthenticated, badResponse(Int), badURL }

struct VoiceTokenClient {
    // Set to your deployed Worker, e.g. https://freewrite-voice-token.<you>.workers.dev
    static let workerBaseURL = URL(string: "https://YOUR-WORKER.workers.dev")!

    func mint(context: VoiceContext, entryId: String?, accessToken: String?) async throws -> VoiceSessionToken {
        guard let accessToken else { throw VoiceTokenError.notAuthenticated }
        var req = URLRequest(url: Self.workerBaseURL.appendingPathComponent("voice/token"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "context": try JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
        ]
        if let entryId { body["entryId"] = entryId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw VoiceTokenError.badResponse(status) }
        struct R: Decodable { let token: String; let wsUrl: String; let sessionId: String }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard let url = URL(string: r.wsUrl) else { throw VoiceTokenError.badURL }
        return VoiceSessionToken(token: r.token, wsURL: url, sessionId: r.sessionId)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add freewrite/Voice/VoiceTokenClient.swift
git commit -m "feat(app): voice token client"
```

### Task C5: `VoiceCoachManager.swift` (LiveKit lifecycle + agent state + transcript)

**Files:**
- Create: `freewrite/Voice/VoiceCoachManager.swift`

- [ ] **Step 1: Implement** (mirrors Jungle web connect flow + `lk.agent.state`)

```swift
// freewrite/Voice/VoiceCoachManager.swift
import Foundation
@preconcurrency import LiveKit

@MainActor
final class VoiceCoachManager: ObservableObject {
    enum Phase: Equatable {
        case idle, authenticating, connecting, listening, speaking, ended
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var micMuted = false
    @Published var micLevel: Float = 0     // drives the waveform
    @Published private(set) var transcript: [TranscriptLine] = []

    struct TranscriptLine: Identifiable { let id = UUID(); let speaker: String; let text: String }

    private var room: Room?
    private var levelTask: Task<Void, Never>?

    func start(context: VoiceContext, entryId: String?) async {
        phase = .authenticating
        let auth = SupabaseAuth.shared
        if !auth.isSignedIn {
            do { try await auth.signInWithGoogle() }
            catch { phase = .error("Sign-in failed"); return }
        }
        phase = .connecting
        do {
            let token = try await VoiceTokenClient().mint(
                context: context, entryId: entryId, accessToken: auth.currentToken())
            let room = Room()
            room.add(delegate: self)
            try await room.connect(url: token.wsURL.absoluteString, token: token.token,
                                   roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
            try await room.localParticipant.setMicrophone(enabled: true)
            self.room = room
            phase = .listening
            startLevelPolling(room)
        } catch let e as VoiceTokenError {
            phase = .error(tokenErrorMessage(e))
        } catch {
            phase = .error("Couldn't reach the coach")
        }
    }

    func toggleMute() async {
        guard let room else { return }
        micMuted.toggle()
        try? await room.localParticipant.setMicrophone(enabled: !micMuted)
    }

    func end() async {
        levelTask?.cancel(); levelTask = nil
        await room?.disconnect()
        room = nil
        phase = .ended
    }

    private func startLevelPolling(_ room: Room) {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.micLevel = room.localParticipant.audioLevel
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func tokenErrorMessage(_ e: VoiceTokenError) -> String {
        switch e {
        case .notAuthenticated: return "Please sign in to use the coach"
        case .badResponse(let s): return "Couldn't start the coach (\(s))"
        case .badURL: return "Server returned a bad address"
        }
    }
}

extension VoiceCoachManager: RoomDelegate {
    // Agent speaking/listening from the lk.agent.state attribute.
    nonisolated func room(_ room: Room, participant: RemoteParticipant,
                          didUpdateAttributes attributes: [String: String]) {
        guard let state = attributes["lk.agent.state"] else { return }
        Task { @MainActor in
            switch state {
            case "speaking": self.phase = .speaking
            case "listening", "thinking": if self.phase != .ended { self.phase = .listening }
            default: break
            }
        }
    }

    // Live transcription stream (lk.transcription).
    nonisolated func room(_ room: Room, participant: Participant?,
                          didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        let isAgent = (participant as? RemoteParticipant) != nil
        Task { @MainActor in
            for seg in segments where seg.final {
                self.transcript.append(.init(speaker: isAgent ? "Coach" : "You", text: seg.text))
            }
        }
    }
}
```

> ⚠️ Part E: the RoomDelegate method names (`didUpdateAttributes`, `didReceiveTranscriptionSegments`) vary by SDK version. Confirm against `client-sdk-swift` 2.x and adjust signatures; the logic (map agent-state → phase; append final segments) is what matters.

- [ ] **Step 2: Commit**

```bash
git add freewrite/Voice/VoiceCoachManager.swift
git commit -m "feat(app): VoiceCoachManager (LiveKit lifecycle + transcript)"
```

### Task C6: `VoiceTranscriptStore.swift` (local + Supabase)

**Files:**
- Create: `freewrite/Voice/VoiceTranscriptStore.swift`

- [ ] **Step 1: Implement** (local mirrors the `Videos/[entry]/transcript.md` convention; cloud insert is best-effort)

```swift
// freewrite/Voice/VoiceTranscriptStore.swift
import Foundation
import Supabase

struct VoiceTranscriptStore {
    /// Local: ~/Documents/Freewrite/VoiceSessions/<entryBase>/<sessionId>/transcript.md (+ meta.json)
    static func saveLocal(entryBase: String, sessionId: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          startedAt: Date, endedAt: Date) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freewrite/VoiceSessions/\(entryBase)/\(sessionId)")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let body = lines.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
        try? body.write(to: docs.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = [
            "sessionId": sessionId, "entryRef": entryBase,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "endedAt": ISO8601DateFormatter().string(from: endedAt),
            "durationSec": Int(endedAt.timeIntervalSince(startedAt)),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: docs.appendingPathComponent("meta.json"))
        }
    }

    /// Cloud: insert into voice_sessions (RLS scopes to the user). Best-effort.
    static func saveCloud(client: SupabaseClient, userId: String, sessionId: String,
                          entryRef: String?, entryType: String,
                          lines: [VoiceCoachManager.TranscriptLine],
                          startedAt: Date, endedAt: Date, model: String) async {
        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        struct Row: Encodable {
            let id: String; let user_id: String; let entry_ref: String?
            let entry_type: String; let started_at: String; let ended_at: String
            let duration_sec: Int; let transcript: String; let model: String
        }
        let row = Row(id: sessionId, user_id: userId, entry_ref: entryRef,
                      entry_type: entryType,
                      started_at: ISO8601DateFormatter().string(from: startedAt),
                      ended_at: ISO8601DateFormatter().string(from: endedAt),
                      duration_sec: Int(endedAt.timeIntervalSince(startedAt)),
                      transcript: transcript, model: model)
        _ = try? await client.from("voice_sessions").insert(row).execute()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add freewrite/Voice/VoiceTranscriptStore.swift
git commit -m "feat(app): persist voice transcript local + Supabase"
```

### Task C7: `VoiceWaveform.swift` + `VoiceCoachOverlay.swift` (UI)

**Files:**
- Create: `freewrite/Voice/VoiceWaveform.swift`
- Create: `freewrite/Voice/VoiceCoachOverlay.swift`

> UI is built to match Freewrite's calm aesthetic and refined live (apply the `ui-self-critique` / `frontend-design` principles at this step). Below is a working, honest first cut.

- [ ] **Step 1: Implement `VoiceWaveform.swift`**

```swift
// freewrite/Voice/VoiceWaveform.swift
import SwiftUI

struct VoiceWaveform: View {
    var level: Float            // 0...1
    var color: Color
    private let bars = 5

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 6, height: barHeight(i))
                    .animation(.easeOut(duration: 0.15), value: level)
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 8
        let center = 1.0 - abs(CGFloat(i) - CGFloat(bars / 2)) / CGFloat(bars)
        return base + CGFloat(level) * 46 * center
    }
}
```

- [ ] **Step 2: Implement `VoiceCoachOverlay.swift`**

```swift
// freewrite/Voice/VoiceCoachOverlay.swift
import SwiftUI

struct VoiceCoachOverlay: View {
    @ObservedObject var manager: VoiceCoachManager
    var colorScheme: ColorScheme
    var onClose: () -> Void

    private var fg: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.20) }
    private var bg: Color { colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.99) }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text(statusText).font(.system(size: 15)).foregroundColor(fg.opacity(0.6))
                VoiceWaveform(level: manager.phase == .speaking ? 0.8 : manager.micLevel,
                              color: fg).frame(height: 60)
                Spacer()
                HStack(spacing: 40) {
                    controlButton(manager.micMuted ? "mic.slash" : "mic") {
                        Task { await manager.toggleMute() }
                    }
                    controlButton("xmark") { Task { await manager.end(); onClose() } }
                }.padding(.bottom, 48)
            }.padding()
        }
        .onChange(of: manager.phase) { _, p in if case .ended = p { onClose() } }
    }

    private var statusText: String {
        switch manager.phase {
        case .authenticating: return "Signing in…"
        case .connecting: return "Connecting to your coach…"
        case .listening: return "Listening…"
        case .speaking: return "Coach is speaking…"
        case .ended, .idle: return ""
        case .error(let m): return m
        }
    }

    private func controlButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 18))
                .foregroundColor(fg).frame(width: 52, height: 52)
                .background(Circle().stroke(fg.opacity(0.25), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add freewrite/Voice/VoiceWaveform.swift freewrite/Voice/VoiceCoachOverlay.swift
git commit -m "feat(app): voice overlay + waveform (first cut, refine live)"
```

### Task C8: Wire the "Voice" button + overlay into `ContentView`

**Files:**
- Modify: `freewrite/ContentView.swift` (Chat button at ~`:1458`; overlay near the video-recording overlay)

- [ ] **Step 1: Add state** (near the other `@State`s, ~`:127`)

```swift
    @State private var showingVoiceCoach = false
    @State private var isHoveringVoice = false
    @StateObject private var voiceManager = VoiceCoachManager()
```

- [ ] **Step 2: Add the button** immediately after the Chat button's closing `}` (after ~`:1605` block). Match the surrounding `•`-separator pattern:

```swift
                            Text("•").foregroundColor(.gray)

                            Button("Voice") {
                                let ctx = currentVoiceContext()
                                showingVoiceCoach = true
                                Task { await voiceManager.start(context: ctx, entryId: selectedEntryId?.uuidString) }
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(isHoveringVoice ? textHoverColor : textColor)
                            .onHover { hovering in
                                isHoveringVoice = hovering
                                isHoveringBottomNav = hovering
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
```

- [ ] **Step 3: Add the overlay** alongside the video-recording overlay (search for `showingVideoRecording` overlay; add a sibling):

```swift
        .overlay {
            if showingVoiceCoach {
                VoiceCoachOverlay(manager: voiceManager, colorScheme: colorScheme) {
                    showingVoiceCoach = false
                }
                .transition(.identity)
            }
        }
```

- [ ] **Step 4: Add the context helper** (near `currentChatSourceText()` at ~`:2145`)

```swift
    private func currentVoiceContext() -> VoiceContext {
        let isVideo = currentVideoURL != nil
        let entryDate = entries.first(where: { $0.id == selectedEntryId })?.date ?? ""
        if isVideo {
            let transcript = currentVideoTranscript() ?? ""   // reuse existing transcript lookup
            return VoiceContext.make(entryType: .video, entryDate: entryDate,
                                     entryText: transcript, hasTranscript: !transcript.isEmpty)
        } else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return VoiceContext.make(entryType: .text, entryDate: entryDate,
                                     entryText: body, hasTranscript: false)
        }
    }
```

> Note: `currentVideoTranscript()` — if no such helper exists, read the saved `transcript.md` for the selected video entry (the app already saves it per spec). Wire to the existing path; if absent, return `nil` and the coach opens by asking about the video.

- [ ] **Step 5: Mic contention guard** — disable Voice while video recording is active. In the Voice button, gate with `.disabled(showingVideoRecording)`.

- [ ] **Step 6: Build**

Run: `xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug build`
Expected: BUILD SUCCEEDED (after Task C0 packages are added).

- [ ] **Step 7: Commit**

```bash
git add freewrite/ContentView.swift
git commit -m "feat(app): Voice button + overlay wired to current entry"
```

### Task C9: URL-callback for OAuth in `freewriteApp.swift`

**Files:**
- Modify: `freewrite/freewriteApp.swift`

- [ ] **Step 1:** Register the URL scheme in Xcode target Info (URL Types → `freewrite`), then handle it:

```swift
        .onOpenURL { url in
            Task { await SupabaseAuth.shared.handleCallback(url: url) }
        }
```

- [ ] **Step 2: Commit**

```bash
git add freewrite/freewriteApp.swift
git commit -m "feat(app): handle OAuth callback URL"
```

---

# PART D — Supabase provisioning — NEEDS YOU (ready-to-paste)

- [ ] **D1:** Create a Supabase project (note the project URL + anon key + JWT secret from Settings ▸ API).
- [ ] **D2:** Auth ▸ Providers ▸ enable **Google**; add the Google OAuth client ID/secret (from Google Cloud Console); add redirect `freewrite://auth-callback` to allowed redirect URLs.
- [ ] **D3:** Run this SQL (SQL Editor):

```sql
create table voice_sessions (
  id           uuid primary key,
  user_id      uuid not null references auth.users(id),
  entry_ref    text,
  entry_type   text,
  started_at   timestamptz not null,
  ended_at     timestamptz,
  duration_sec int,
  transcript   text,
  model        text,
  created_at   timestamptz default now()
);
alter table voice_sessions enable row level security;
create policy "own rows" on voice_sessions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
```

- [ ] **D4:** Put the project URL + anon key into `SupabaseAuth.swift` (Task C3) and a `SupabaseClient` accessible to `VoiceTranscriptStore` (inject the shared client). Put the **JWT secret** into the Worker: `wrangler secret put SUPABASE_JWT_SECRET`.

---

# PART E — Deploy + end-to-end voice — NEEDS YOU (runbook)

- [ ] **E1 — Worker:** `cd backend/voice-token-worker && npx wrangler secret put LIVEKIT_URL` (+ `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `SUPABASE_JWT_SECRET`), then `npx wrangler deploy`. Put the deployed URL into `VoiceTokenClient.workerBaseURL` (Task C4).
- [ ] **E2 — LiveKit + AI Gateway:** create a LiveKit Cloud project (get URL/key/secret). Create a Cloudflare AI Gateway (get the compat URL + key). Gather Deepgram + ElevenLabs keys (reuse Jungle's per your call).
- [ ] **E3 — Agent deploy:** `cd backend/voice-coach-agent`, set the env (E2 values), `lk agent create` then `lk agent deploy` (registers `freewrite-coach`). First, run locally once: `python agent.py dev` and confirm imports/plugin versions resolve (fix any 1.5 import drift flagged in Task B4).
- [ ] **E4 — Smoke test (the only true end-to-end check):**
  1. Build/run the app. Open a text entry with a few sentences.
  2. Press **Voice** → Google sign-in → grant mic.
  3. Confirm: overlay → connecting → coach **greets referencing what you wrote** → you speak → it responds.
  4. Press end. Confirm `~/Documents/Freewrite/VoiceSessions/<entry>/<session>/transcript.md` exists and a `voice_sessions` row appears in Supabase.
  5. Repeat on a **video** entry (uses its transcript) and an **empty** entry (opens open-ended).
  6. Verify Voice is disabled while a video recording is active.
- [ ] **E5 — Privacy check:** confirm no journal text appears in any analytics; only voice-session data left the device.

---

## Self-review

**Spec coverage:** §4 architecture → Parts A/B/C/E. §5.1 Swift feature → C2–C9. §5.2 Supabase → C3/D. §5.3 Worker → A. §5.4 agent + LLM decision → B (default Option 2, switchable in `_build_llm`). §6 lifecycle → C5/C8. §7 context+capping → A2/B2/C2 (three layers). §8 data model → C6/D3. §9 privacy → E5. §10 prompt → B3 (tools correctly absent in v1). §11 UI + mic-contention → C7/C8. §12 auth+entitlement → C1/C3/C9. §13 secrets → A6/E. §14 errors → C5 (token-error mapping; full taxonomy refined live). §15 cost/cap → caps in A2/C2. §16 sequencing → Parts order. §17 testing → per-task tests + E4.

**Placeholder scan:** Persona prose in B3 is intentionally a labeled placeholder (Julian refines; tests assert behavior not wording). The `YOUR-PROJECT`/`YOUR-WORKER` literals are config you fill in D/E — flagged, not hidden. No "TODO/handle edge cases" hand-waves in executable steps.

**Type consistency:** `VoiceContext` keys (entryType/entryDate/entryText/hasTranscript/truncated/modality) match across Worker (`context.ts` `VoiceContext`), agent (`context.py` reads same keys), and Swift (`VoiceContext`). Worker `signLiveKitToken` arg names match its test. `handleToken(request, env)` signature matches its test. `VoiceCoachManager.Phase`/`TranscriptLine` used consistently in overlay.

**Known runtime-verify points (flagged inline, not placeholders):** livekit-agents 1.5 import paths (B4), supabase-swift OAuth API (C3), client-sdk-swift RoomDelegate signatures (C5). These are SDK-version confirmations done at first compile/run in Part E — the *logic* is fixed and tested.
