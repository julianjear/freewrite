import { describe, it, expect } from "vitest";
import { SignJWT, jwtVerify, generateKeyPair } from "jose";
import { handleToken, type Env } from "./index";

// jose's generateKeyPair returns KeyLike; cast to CryptoKey to satisfy tsc
// (identical at runtime on Web Crypto).
async function es256() {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  return { publicKey: publicKey as CryptoKey, privateKey: privateKey as CryptoKey };
}

const enc = new TextEncoder();
const env: Env = {
  LIVEKIT_URL: "wss://test.livekit.cloud",
  LIVEKIT_API_KEY: "APItestkey",
  LIVEKIT_API_SECRET: "supersecretvalue-supersecretvalue",
  SUPABASE_URL: "https://test.supabase.co",
  COACH_AGENT_NAME: "freewrite-coach",
  ALLOWED_ORIGIN: "*",
  TOKEN_TTL_SECONDS: "1200",
};
const ISSUER = `${env.SUPABASE_URL}/auth/v1`;

async function userToken(privateKey: CryptoKey) {
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({ email: "a@b.com" })
    .setProtectedHeader({ alg: "ES256" })
    .setSubject("user-abc")
    .setIssuer(ISSUER)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);
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
    const { publicKey } = await es256();
    const res = await handleToken(req({ context: {} }), env, publicKey);
    expect(res.status).toBe(401);
  });

  it("401 on a token signed by the wrong key", async () => {
    const signer = await es256();
    const other = await es256();
    const res = await handleToken(
      req({ context: {} }, await userToken(signer.privateKey)),
      env,
      other.publicKey,
    );
    expect(res.status).toBe(401);
  });

  it("200 returns token+wsUrl+sessionId; token carries capped context in metadata", async () => {
    const { publicKey, privateKey } = await es256();
    const ctx = {
      entryType: "text",
      entryDate: "May 30",
      entryText: "I keep avoiding the hard conversation.",
      hasTranscript: false,
      modality: "voice",
    };
    const res = await handleToken(
      req({ context: ctx, entryId: "entry-1" }, await userToken(privateKey)),
      env,
      publicKey,
    );
    expect(res.status).toBe(200);
    const json = (await res.json()) as any;
    expect(json.wsUrl).toBe(env.LIVEKIT_URL);
    expect(json.sessionId).toMatch(/^freewrite-user-abc-entry-1-\d+$/);
    const { payload } = await jwtVerify(json.token, enc.encode(env.LIVEKIT_API_SECRET));
    const meta = JSON.parse(payload.metadata as string);
    expect(meta.userId).toBe("user-abc");
    expect(meta.context.entryText).toContain("hard conversation");
    expect(meta.context.truncated).toBe(false);
  });

  it("400 on malformed JSON body", async () => {
    const { publicKey, privateKey } = await es256();
    const bad = new Request("https://w/voice/token", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${await userToken(privateKey)}`,
      },
      body: "{not json",
    });
    const res = await handleToken(bad, env, publicKey);
    expect(res.status).toBe(400);
  });
});
