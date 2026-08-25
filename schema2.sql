-- ============================================================
-- Arena v2 - Matchmaking + Games Schema
-- Run this in Supabase SQL Editor AFTER your original schema.sql
-- ============================================================
-- 1. Allow users to update their OWN wallet row.
create policy "Users can update their own wallet"
  on public.wallet for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
-- 2. MATCHMAKING QUEUE
create table if not exists public.matchmaking_queue (
  user_id uuid primary key references public.users (id) on delete cascade,
  game_type text not null,
  created_at timestamptz not null default now()
);
alter table public.matchmaking_queue enable row level security;
create policy "Users can see the queue"
  on public.matchmaking_queue for select
  using (true);
create policy "Users can join the queue as themselves"
  on public.matchmaking_queue for insert
  with check (auth.uid() = user_id);
create policy "Users can leave the queue"
  on public.matchmaking_queue for delete
  using (auth.uid() = user_id);
-- 3. MATCHES
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users (id),
  player2_id uuid not null references public.users (id),
  status text not null default 'active', -- 'active' | 'finished'
  winner_id uuid references public.users (id),
  entry_fee integer not null default 50,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
alter table public.matches enable row level security;
create policy "Players can view their own matches"
  on public.matches for select
  using (auth.uid() = player1_id or auth.uid() = player2_id);
create policy "Players can create a match they are part of"
  on public.matches for insert
  with check (auth.uid() = player1_id or auth.uid() = player2_id);
create policy "Players can update their own matches"
  on public.matches for update
  using (auth.uid() = player1_id or auth.uid() = player2_id);
-- ============================================================
-- After running this, go to Database > Replication in Supabase
-- and make sure "matches" has Realtime enabled (toggle it on),
-- so both players get notified instantly when a match is created.
-- ============================================================

-- ============================================================
-- Arena v3 - Enable Realtime on wallet for live balance sync
-- Needed so a user's balance updates instantly across every
-- open tab/device the moment a deduction or credit happens,
-- without requiring a page refresh or re-login.
-- ============================================================
alter publication supabase_realtime add table public.wallet;
