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
      canPublishSources: ["microphone"],
      canPublishData: false,
      canSubscribe: true,
      canUpdateOwnMetadata: false,
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
