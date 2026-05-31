-- Freewrite Voice Coach — Supabase schema (Part D of the thin-slice plan).
-- Run in the Supabase SQL Editor after creating the project.
--
-- Stores one row per completed voice-coaching session. RLS scopes every row to
-- its owner so a user can only ever read/write their own sessions.

create table if not exists voice_sessions (
  id           uuid primary key,            -- = sessionId / LiveKit room name
  user_id      uuid not null references auth.users(id) on delete cascade,
  entry_ref    text,                        -- entry filename/base; null for transient
  entry_type   text,                        -- 'text' | 'video'
  started_at   timestamptz not null,
  ended_at     timestamptz,
  duration_sec int,
  transcript   text,                        -- speaker-labeled conversation
  model        text,                        -- e.g. 'gemini-2.5-flash'
  created_at   timestamptz default now()
);

alter table voice_sessions enable row level security;

-- Single policy: a user may do anything to rows they own, nothing to others'.
drop policy if exists "own rows" on voice_sessions;
create policy "own rows" on voice_sessions
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Helpful index for listing a user's sessions newest-first.
create index if not exists voice_sessions_user_started_idx
  on voice_sessions (user_id, started_at desc);
