import { jwtVerify, createRemoteJWKSet } from "jose";

export interface AuthedUser {
  userId: string;
  email: string | null;
}

// Supabase signs access tokens with ES256 (asymmetric). Public keys live at
// <supabaseUrl>/auth/v1/.well-known/jwks.json. createRemoteJWKSet caches keys
// in-isolate, so reusing the returned resolver across requests is cheap.
export function supabaseJWKS(supabaseUrl: string) {
  return createRemoteJWKSet(
    new URL(`${supabaseUrl}/auth/v1/.well-known/jwks.json`),
  );
}

// Verify a Supabase access token. `key` is a remote JWKS resolver in production
// (from supabaseJWKS) or a public key in tests. jwtVerify enforces the
// signature + expiry; we additionally pin the issuer so a token from another
// Supabase project can't be replayed against ours.
export async function verifySupabaseJWT(
  token: string,
  key: Parameters<typeof jwtVerify>[1],
  opts?: { issuer?: string },
): Promise<AuthedUser> {
  const { payload } = await jwtVerify(
    token,
    key,
    opts?.issuer ? { issuer: opts.issuer } : {},
  );
  const userId = typeof payload.sub === "string" ? payload.sub : "";
  if (!userId) throw new Error("token has no subject");
  const email = typeof payload.email === "string" ? payload.email : null;
  return { userId, email };
}
