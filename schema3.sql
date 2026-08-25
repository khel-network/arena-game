-- ============================================================
-- Arena v3 - Persisted Wallet Ledger + Match History
-- Run this in Supabase SQL Editor AFTER schema.sql and schema2.sql
-- Fixes: transactions/match history were only stored in the browser's
-- localStorage, so refreshing (or opening on another device) showed
-- stale data. These tables make them real, synced, per-user records.
-- ============================================================

-- 1. TRANSACTIONS (wallet ledger)
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  description text not null,
  type text not null check (type in ('credit', 'debit')),
  amount integer not null check (amount >= 0),
  created_at timestamptz not null default now()
);

alter table public.transactions enable row level security;

create policy "Users can view their own transactions"
  on public.transactions for select
  using (auth.uid() = user_id);

create policy "Users can insert their own transactions"
  on public.transactions for insert
  with check (auth.uid() = user_id);

create index if not exists transactions_user_id_created_at_idx
  on public.transactions (user_id, created_at desc);

-- 2. MATCH HISTORY
create table if not exists public.match_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  game text not null,
  opponent text not null,
  result text not null check (result in ('VICTORY', 'DEFEAT', 'DRAW')),
  reward integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.match_history enable row level security;

create policy "Users can view their own match history"
  on public.match_history for select
  using (auth.uid() = user_id);

create policy "Users can insert their own match history"
  on public.match_history for insert
  with check (auth.uid() = user_id);

create index if not exists match_history_user_id_created_at_idx
  on public.match_history (user_id, created_at desc);

-- ============================================================
-- After running this, the dashboard will read/write these tables
-- directly, so balances, ledger entries, and match records will
-- persist correctly across refreshes and devices.
-- ============================================================
