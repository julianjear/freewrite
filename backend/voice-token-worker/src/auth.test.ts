import { describe, it, expect } from "vitest";
import { SignJWT, generateKeyPair } from "jose";
import { verifySupabaseJWT } from "./auth";

const ISSUER = "https://test.supabase.co/auth/v1";

// jose's generateKeyPair returns KeyLike; at runtime on Web Crypto these ARE
// CryptoKey, but the static types differ. Cast to keep tsc happy.
async function es256() {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  return { publicKey: publicKey as CryptoKey, privateKey: privateKey as CryptoKey };
}

async function makeToken(
  privateKey: CryptoKey,
  opts: { sub?: string; expOffset?: number; issuer?: string; audience?: string; role?: string },
) {
  const now = Math.floor(Date.now() / 1000);
  return await new SignJWT({ role: opts.role ?? "authenticated", email: "a@b.com" })
    .setProtectedHeader({ alg: "ES256" })
    .setSubject(opts.sub ?? "user-abc")
    .setIssuer(opts.issuer ?? ISSUER)
    .setAudience(opts.audience ?? "authenticated")
    .setIssuedAt(now)
    .setExpirationTime(now + (opts.expOffset ?? 3600))
    .sign(privateKey);
}

describe("verifySupabaseJWT (ES256)", () => {
  it("returns userId + email for a valid token", async () => {
    const { publicKey, privateKey } = await es256();
    const token = await makeToken(privateKey, {});
    const r = await verifySupabaseJWT(token, publicKey, { issuer: ISSUER, audience: "authenticated" });
    expect(r.userId).toBe("user-abc");
    expect(r.email).toBe("a@b.com");
  });

  it("throws on expired token", async () => {
    const { publicKey, privateKey } = await es256();
    const token = await makeToken(privateKey, { expOffset: -10 });
    await expect(
      verifySupabaseJWT(token, publicKey, { issuer: ISSUER, audience: "authenticated" }),
    ).rejects.toThrow();
  });

  it("throws when signed by a different key (forged signature)", async () => {
    const signer = await es256();
    const other = await es256();
    const token = await makeToken(signer.privateKey, {});
    await expect(
      verifySupabaseJWT(token, other.publicKey, { issuer: ISSUER, audience: "authenticated" }),
    ).rejects.toThrow();
  });

  it("throws on issuer mismatch (token from another project)", async () => {
    const { publicKey, privateKey } = await es256();
    const token = await makeToken(privateKey, {
      issuer: "https://evil.supabase.co/auth/v1",
    });
    await expect(
      verifySupabaseJWT(token, publicKey, { issuer: ISSUER, audience: "authenticated" }),
    ).rejects.toThrow();
  });

  it("throws on audience mismatch or non-authenticated role", async () => {
    const { publicKey, privateKey } = await es256();
    await expect(verifySupabaseJWT(
      await makeToken(privateKey, { audience: "other" }), publicKey,
      { issuer: ISSUER, audience: "authenticated" },
    )).rejects.toThrow();
    await expect(verifySupabaseJWT(
      await makeToken(privateKey, { role: "anon" }), publicKey,
      { issuer: ISSUER, audience: "authenticated" },
    )).rejects.toThrow();
  });
});
