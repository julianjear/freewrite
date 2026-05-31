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
