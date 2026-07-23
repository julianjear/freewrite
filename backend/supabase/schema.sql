-- Freewrite Voice Coach — Supabase schema (Part D of the thin-slice plan).
-- Run in the Supabase SQL Editor after creating the project.
--
-- Stores one row per completed voice-coaching session. RLS scopes every row to
-- its owner so a user can only ever read/write their own sessions.

create table if not exists voice_sessions (
  id           uuid primary key default gen_random_uuid(),
  session_id   text,                        -- opaque LiveKit room/session name
  user_id      uuid not null references auth.users(id) on delete cascade,
  entry_ref    text,                        -- entry filename/base; null for transient
  entry_type   text,                        -- 'text' | 'video'
  started_at   timestamptz not null,
  ended_at     timestamptz,
  duration_sec int,
  transcript   text,                        -- speaker-labeled conversation
  architecture text,                        -- 'cascade' | 'realtime'
  provider     text,
  model        text,
  voice_config jsonb not null default '{}'::jsonb,
  telemetry_events jsonb not null default '[]'::jsonb,
  strategy_briefs jsonb not null default '[]'::jsonb,
  estimated_cost_usd numeric(14, 8),
  created_at   timestamptz default now()
);

-- Migration-safe additions for projects that already ran the original thin
-- slice schema. The old client incorrectly used a non-UUID room name as `id`;
-- new clients omit id, use its UUID default, and store the room in session_id.
alter table voice_sessions alter column id set default gen_random_uuid();
alter table voice_sessions add column if not exists session_id text;
alter table voice_sessions add column if not exists architecture text;
alter table voice_sessions add column if not exists provider text;
alter table voice_sessions add column if not exists voice_config jsonb not null default '{}'::jsonb;
alter table voice_sessions add column if not exists telemetry_events jsonb not null default '[]'::jsonb;
alter table voice_sessions add column if not exists strategy_briefs jsonb not null default '[]'::jsonb;
alter table voice_sessions add column if not exists estimated_cost_usd numeric(14, 8);
create unique index if not exists voice_sessions_session_id_idx
  on voice_sessions (session_id) where session_id is not null;

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
