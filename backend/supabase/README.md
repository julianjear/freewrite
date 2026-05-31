# Supabase setup (Part D)

Provisioning steps for the Voice Coach's auth + cloud storage. These require a
Supabase account (one-time, by Julian).

## 1. Create the project
- New project at https://supabase.com. Note from **Settings ▸ API**:
  - Project URL (`https://<ref>.supabase.co`)
  - `anon` public key (publishable — goes in the app)
  - JWT secret (Settings ▸ API ▸ JWT Settings) — goes in the **Worker** secret `SUPABASE_JWT_SECRET`

## 2. Enable Google sign-in
- **Authentication ▸ Providers ▸ Google** → enable.
- Create an OAuth client in Google Cloud Console (type: Desktop/iOS or Web as appropriate); paste client ID + secret into Supabase.
- **Authentication ▸ URL Configuration ▸ Redirect URLs**: add `freewrite://auth-callback`.

## 3. Create the table
- **SQL Editor** → paste and run [`schema.sql`](./schema.sql).

## 4. Wire the values
- App (`freewrite/Voice/SupabaseAuth.swift`): set `supabaseURL` + anon key.
- Worker: `cd backend/voice-token-worker && npx wrangler secret put SUPABASE_JWT_SECRET` (paste the JWT secret).

## Notes
- This project verifies Supabase access tokens as **HS256** (the project JWT
  secret). If you switch the project to asymmetric (ES256/RS256) JWT signing
  keys later, update the Worker's `verifySupabaseJWT` to fetch the JWKS instead
  of using a shared secret.
- Only voice-session transcripts go to the cloud. Journal entries stay local.
