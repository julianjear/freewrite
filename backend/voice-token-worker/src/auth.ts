import { jwtVerify, createRemoteJWKSet } from "jose";

export interface AuthedUser {
  userId: string;
  email: string | null;
}

// A remote JWKS resolver (production) or a single public key (tests).
export type VerifyKey = CryptoKey | ReturnType<typeof createRemoteJWKSet>;

// Supabase signs access tokens with ES256 (asymmetric). Public keys live at
// <supabaseUrl>/auth/v1/.well-known/jwks.json. createRemoteJWKSet caches keys
// in-isolate, so reusing the returned resolver across requests is cheap.
export function supabaseJWKS(supabaseUrl: string): ReturnType<typeof createRemoteJWKSet> {
  return createRemoteJWKSet(
    new URL(`${supabaseUrl}/auth/v1/.well-known/jwks.json`),
  );
}

// Verify a Supabase access token. jwtVerify enforces signature + expiry; we
// additionally pin the issuer so a token from another Supabase project can't be
// replayed against ours. The `typeof key === "function"` split lets each branch
// match the right jwtVerify overload (getKey resolver vs. a single key).
export async function verifySupabaseJWT(
  token: string,
  key: VerifyKey,
  opts?: { issuer?: string },
): Promise<AuthedUser> {
  const options = opts?.issuer ? { issuer: opts.issuer } : {};
  const { payload } =
    typeof key === "function"
      ? await jwtVerify(token, key, options)
      : await jwtVerify(token, key, options);
  const userId = typeof payload.sub === "string" ? payload.sub : "";
  if (!userId) throw new Error("token has no subject");
  const email = typeof payload.email === "string" ? payload.email : null;
  return { userId, email };
}
