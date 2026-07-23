import { verifySupabaseJWT, supabaseJWKS, type VerifyKey } from "./auth";
import { signLiveKitToken } from "./token";
import { handleChat } from "./chat";
import {
  capEntryText,
  MAX_CHAT_HISTORY_BYTES,
  MAX_STARTING_QUESTION_BYTES,
  buildRoomName,
  buildMetadata,
  parseVoiceConfig,
  sanitizeEntryId,
  VOICE_PROFILES,
  type VoiceContext,
} from "./context";

// Narrow dependency contract for unit-testing the token handler. The deployed
// fetch handler uses Wrangler's generated global `Env` from
// worker-configuration.d.ts as the binding source of truth.
export interface VoiceTokenEnv {
  LIVEKIT_URL: string;
  LIVEKIT_API_KEY: string;
  LIVEKIT_API_SECRET: string;
  SUPABASE_URL: string;
  COACH_AGENT_NAME: string;
  ALLOWED_ORIGIN: string;
  TOKEN_TTL_SECONDS: string;
  ENABLED_VOICE_PROVIDERS: string;
  ENABLED_STRATEGIST_PROVIDERS: string;
  VOICE_TOKEN_RATE_LIMITER: RateLimit;
}

function enabled(value: string): Set<string> {
  return new Set((value || "").split(",").map((item) => item.trim().toLowerCase()).filter(Boolean));
}

function strategistProvider(model: string): string {
  if (model.startsWith("gemini-")) return "google";
  if (model.startsWith("claude-")) return "anthropic";
  if (model.startsWith("gpt-")) return "openai";
  return "unknown";
}

const MAX_REQUEST_BYTES = 16 * 1024;
let cachedJwks: { url: string; getKey: ReturnType<typeof supabaseJWKS> } | null = null;

function jwksFor(url: string): ReturnType<typeof supabaseJWKS> {
  if (!cachedJwks || cachedJwks.url !== url) cachedJwks = { url, getKey: supabaseJWKS(url) };
  return cachedJwks.getKey;
}

function cors(env: VoiceTokenEnv, origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type",
    Vary: "Origin",
  };
  const allowed = env.ALLOWED_ORIGIN.split(",").map((v) => v.trim()).filter(Boolean);
  if (origin && (allowed.includes("*") || allowed.includes(origin))) {
    headers["Access-Control-Allow-Origin"] = allowed.includes("*") ? "*" : origin;
  }
  return headers;
}

function json(body: unknown, status: number, env: VoiceTokenEnv, origin: string | null = null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...cors(env, origin) },
  });
}

async function readBoundedJSON(request: Request): Promise<unknown> {
  const length = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(length) && length > MAX_REQUEST_BYTES) throw new Error("body too large");
  if (!request.body) throw new Error("missing body");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_REQUEST_BYTES) {
      await reader.cancel();
      throw new Error("body too large");
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(all));
}

function safeTTL(value: string): number {
  const parsed = Number.parseInt(value || "1200", 10);
  if (!Number.isFinite(parsed)) return 1200;
  return Math.min(3600, Math.max(60, parsed));
}

export async function handleToken(request: Request, env: VoiceTokenEnv, verifyKey?: VerifyKey): Promise<Response> {
  const origin = request.headers.get("origin");
  const authHeader = request.headers.get("authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "missing bearer token" }, 401, env, origin);

  let user;
  try {
    user = await verifySupabaseJWT(
      authHeader.slice(7).trim(),
      verifyKey ?? jwksFor(env.SUPABASE_URL),
      { issuer: `${env.SUPABASE_URL}/auth/v1`, audience: "authenticated" },
    );
  } catch {
    return json({ error: "invalid token" }, 401, env, origin);
  }

  const rate = await env.VOICE_TOKEN_RATE_LIMITER.limit({ key: user.userId });
  if (!rate.success) return json({ error: "rate limit exceeded" }, 429, env, origin);

  let body: Record<string, unknown>;
  try {
    const decoded = await readBoundedJSON(request);
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) throw new Error("body must be an object");
    body = decoded as Record<string, unknown>;
  } catch (error) {
    const message = error instanceof Error && error.message === "body too large" ? "body too large" : "invalid json";
    return json({ error: message }, message === "body too large" ? 413 : 400, env, origin);
  }

  let voiceConfig;
  let entryId;
  try {
    voiceConfig = parseVoiceConfig(body.voiceConfig);
    entryId = sanitizeEntryId(body.entryId);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "invalid request" }, 400, env, origin);
  }

  const voiceProvider = VOICE_PROFILES[voiceConfig.profileId][1];
  if (!enabled(env.ENABLED_VOICE_PROVIDERS).has(voiceProvider)) {
    return json({
      error: `${voiceProvider} voice models are not configured on the active coach agent`,
      code: "provider_not_configured",
      provider: voiceProvider,
      profileId: voiceConfig.profileId,
    }, 409, env, origin);
  }
  const supervisorProvider = strategistProvider(voiceConfig.supervisorModel);
  if (voiceConfig.supervisorEnabled && !enabled(env.ENABLED_STRATEGIST_PROVIDERS).has(supervisorProvider)) {
    return json({
      error: `${supervisorProvider} strategist models are not configured on the active coach agent`,
      code: "strategist_not_configured",
      provider: supervisorProvider,
      model: voiceConfig.supervisorModel,
    }, 409, env, origin);
  }

  const raw = (body.context ?? {}) as Record<string, unknown>;
  const capped = capEntryText(typeof raw.entryText === "string" ? raw.entryText : "");
  const cappedChat = capEntryText(typeof raw.chatHistory === "string" ? raw.chatHistory : "", MAX_CHAT_HISTORY_BYTES);
  const cappedQuestion = capEntryText(
    typeof raw.startingQuestion === "string" ? raw.startingQuestion : "",
    MAX_STARTING_QUESTION_BYTES,
  );
  const context: VoiceContext = {
    entryType: raw.entryType === "video" ? "video" : "text",
    entryDate: typeof raw.entryDate === "string" ? raw.entryDate.slice(0, 64) : "",
    entryText: capped.text,
    hasTranscript: raw.hasTranscript === true,
    chatHistory: cappedChat.text,
    startingQuestion: cappedQuestion.text || null,
    truncated: capped.truncated,
    modality: "voice",
  };

  const nowMs = Date.now();
  const roomName = buildRoomName(crypto.randomUUID(), nowMs);
  const metadata = buildMetadata(user.userId, context, voiceConfig, entryId);
  const token = await signLiveKitToken({
    apiKey: env.LIVEKIT_API_KEY,
    apiSecret: env.LIVEKIT_API_SECRET,
    identity: user.userId,
    roomName,
    metadata,
    agentName: env.COACH_AGENT_NAME,
    ttlSeconds: safeTTL(env.TOKEN_TTL_SECONDS),
    nowMs,
  });

  console.log({
    event: "voice_token_minted",
    sessionId: roomName,
    profileId: voiceConfig.profileId,
    architecture: voiceConfig.profileId.startsWith("realtime-") ? "realtime" : "cascade",
    contextBytes: Buffer.byteLength(context.entryText, "utf8"),
  });
  return json({ token, wsUrl: env.LIVEKIT_URL, sessionId: roomName, voiceConfig }, 200, env, origin);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const origin = request.headers.get("origin");
    if (request.method === "OPTIONS") {
      const allowed = cors(env, origin);
      return new Response(null, { status: origin && !allowed["Access-Control-Allow-Origin"] ? 403 : 204, headers: allowed });
    }
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/voice/token") return handleToken(request, env);
    if (request.method === "POST" && url.pathname === "/chat/stream") return handleChat(request, env, ctx);
    return json({ error: "not found" }, 404, env, origin);
  },
} satisfies ExportedHandler<Env>;
