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
    // Pin jose's clock to the same fixed nowMs so exp/nbf validate against the
    // token's own timeframe (the token deliberately uses a fixed past instant).
    const { payload } = await jwtVerify(jwt, new TextEncoder().encode(SECRET), {
      currentDate: new Date(1700000000000),
    });
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
