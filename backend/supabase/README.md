# Supabase setup (Part D)

Provisioning steps for the Voice Coach's auth + cloud storage. These require a
Supabase account (one-time, by Julian).

## 1. Create the project
- New project at https://supabase.com. Note from **Settings ▸ API**:
  - Project URL (`https://<ref>.supabase.co`)
  - `anon` public key (publishable — goes in the app)

## 2. Enable Google sign-in
- **Authentication ▸ Providers ▸ Google** → enable.
- Create an OAuth client in Google Cloud Console (type: Desktop/iOS or Web as appropriate); paste client ID + secret into Supabase.
- **Authentication ▸ URL Configuration ▸ Redirect URLs**: add `freewrite://auth-callback`.

## 3. Create the table
- **SQL Editor** → paste and run [`schema.sql`](./schema.sql).

## 4. Wire the values
- App (`freewrite/Voice/SupabaseAuth.swift`): set `supabaseURL` + anon key.
- Worker (`backend/voice-token-worker/wrangler.toml`): set `SUPABASE_URL`.
- Worker secrets: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, and
  `LIVEKIT_API_SECRET`. Supabase token verification needs no shared secret.

## Notes
- The Worker verifies asymmetric Supabase access tokens against the project's
  public JWKS and pins issuer, `authenticated` audience, and role.
- Completed sessions store transcripts, selected configuration, sampled
  telemetry events, strategy briefs, and estimated cost. Journal entries stay
  local; only an optional entry reference is attached to the session row.
