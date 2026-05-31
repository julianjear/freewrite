import { verifySupabaseJWT, supabaseJWKS, type VerifyKey } from "./auth";
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
  SUPABASE_URL: string;
  COACH_AGENT_NAME: string;
  ALLOWED_ORIGIN: string;
  TOKEN_TTL_SECONDS: string;
}

// Cache the JWKS resolver per Supabase URL across requests in this isolate.
let cachedJwks: { url: string; getKey: ReturnType<typeof supabaseJWKS> } | null = null;
function jwksFor(url: string): ReturnType<typeof supabaseJWKS> {
  if (!cachedJwks || cachedJwks.url !== url) {
    cachedJwks = { url, getKey: supabaseJWKS(url) };
  }
  return cachedJwks.getKey;
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

// `verifyKey` is injectable for tests (a local public key); in production it
// defaults to the cached remote JWKS resolver for env.SUPABASE_URL.
export async function handleToken(
  request: Request,
  env: Env,
  verifyKey?: VerifyKey,
): Promise<Response> {
  // Auth
  const authHeader = request.headers.get("authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) {
    return json({ error: "missing bearer token" }, 401, env);
  }
  let user;
  try {
    user = await verifySupabaseJWT(
      authHeader.slice(7).trim(),
      verifyKey ?? jwksFor(env.SUPABASE_URL),
      { issuer: `${env.SUPABASE_URL}/auth/v1` },
    );
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
