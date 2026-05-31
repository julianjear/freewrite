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
