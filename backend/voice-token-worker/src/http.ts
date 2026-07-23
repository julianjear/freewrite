export interface AllowedOriginEnv {
  ALLOWED_ORIGIN: string;
}

export function cors(env: AllowedOriginEnv, origin: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, content-type",
    Vary: "Origin",
  };
  const allowed = env.ALLOWED_ORIGIN.split(",").map((value) => value.trim()).filter(Boolean);
  if (origin && (allowed.includes("*") || allowed.includes(origin))) {
    headers["Access-Control-Allow-Origin"] = allowed.includes("*") ? "*" : origin;
  }
  return headers;
}

export function json(
  body: unknown,
  status: number,
  env: AllowedOriginEnv,
  origin: string | null = null,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...cors(env, origin) },
  });
}
