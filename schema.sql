-- ============================================================
-- SkillClash - MASTER SCHEMA v9
-- ============================================================
-- Includes:
--   - v4 base: users, wallet, matchmaking, matches, transactions,
--     match_history, game_sessions, claim_opponent, referrals,
--     payment_requests, welcome bonus, realtime for game_sessions
--   - v9 additions: match_invites (with realtime), terms/age
--     acceptance tracking, expire_old_invites, accept_match_invite
--
-- Safe to re-run. All statements are idempotent:
--   add column if not exists / create table if not exists /
--   drop policy if exists then create / create or replace function /
--   DO blocks that swallow duplicate_object errors.
-- ============================================================


-- ------------------------------------------------------------
-- USERS
-- ------------------------------------------------------------
create table if not exists public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.users add column if not exists last_seen timestamptz not null default now();
alter table public.users add column if not exists referral_code text;
alter table public.users add column if not exists referred_by uuid references public.users (id);

-- v9 additions on users:
alter table public.users add column if not exists terms_accepted_at timestamptz;
alter table public.users add column if not exists age_confirmed boolean not null default false;

create unique index if not exists users_referral_code_key
  on public.users (referral_code) where referral_code is not null;

alter table public.users enable row level security;

drop policy if exists "Users can view their own profile" on public.users;
drop policy if exists "Authenticated users can view profiles" on public.users;
create policy "Authenticated users can view profiles"
  on public.users for select
  using (auth.role() = 'authenticated');

drop policy if exists "Users can update their own profile" on public.users;
create policy "Users can update their own profile"
  on public.users for update using (auth.uid() = id);

drop policy if exists "Users can insert their own profile" on public.users;
create policy "Users can insert their own profile"
  on public.users for insert with check (auth.uid() = id);


-- ------------------------------------------------------------
-- WALLET - Default balance is 50 (welcome bonus)
-- ------------------------------------------------------------
create table if not exists public.wallet (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users (id) on delete cascade,
  dummy_token integer not null default 50 check (dummy_token >= 0),
  updated_at timestamptz not null default now()
);

alter table public.wallet enable row level security;

drop policy if exists "Users can view their own wallet" on public.wallet;
create policy "Users can view their own wallet"
  on public.wallet for select using (auth.uid() = user_id);

drop policy if exists "Users can update their own wallet" on public.wallet;
create policy "Users can update their own wallet"
  on public.wallet for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "Users can insert their own wallet" on public.wallet;
create policy "Users can insert their own wallet"
  on public.wallet for insert with check (auth.uid() = user_id);


-- ------------------------------------------------------------
-- MATCHMAKING QUEUE
-- ------------------------------------------------------------
create table if not exists public.matchmaking_queue (
  user_id uuid primary key references public.users (id) on delete cascade,
  game_type text not null,
  created_at timestamptz not null default now()
);

alter table public.matchmaking_queue enable row level security;

drop policy if exists "Users can see the queue" on public.matchmaking_queue;
create policy "Users can see the queue"
  on public.matchmaking_queue for select using (true);

drop policy if exists "Users can join the queue as themselves" on public.matchmaking_queue;
create policy "Users can join the queue as themselves"
  on public.matchmaking_queue for insert with check (auth.uid() = user_id);

drop policy if exists "Users can leave the queue" on public.matchmaking_queue;
create policy "Users can leave the queue"
  on public.matchmaking_queue for delete using (auth.uid() = user_id);


-- ------------------------------------------------------------
-- MATCHES
-- ------------------------------------------------------------
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users (id),
  player2_id uuid not null references public.users (id),
  status text not null default 'active',
  winner_id uuid references public.users (id),
  entry_fee integer not null default 15,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

alter table public.matches enable row level security;

drop policy if exists "Players can view their own matches" on public.matches;
create policy "Players can view their own matches"
  on public.matches for select
  using (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can create a match they are part of" on public.matches;
create policy "Players can create a match they are part of"
  on public.matches for insert
  with check (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can update their own matches" on public.matches;
create policy "Players can update their own matches"
  on public.matches for update
  using (auth.uid() = player1_id or auth.uid() = player2_id);


-- ------------------------------------------------------------
-- TRANSACTIONS (token ledger)
-- ------------------------------------------------------------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  description text not null,
  type text not null check (type in ('credit', 'debit')),
  amount integer not null,
  created_at timestamptz not null default now()
);

alter table public.transactions enable row level security;

drop policy if exists "Users can view their own transactions" on public.transactions;
create policy "Users can view their own transactions"
  on public.transactions for select using (auth.uid() = user_id);

drop policy if exists "Users can insert their own transactions" on public.transactions;
create policy "Users can insert their own transactions"
  on public.transactions for insert with check (auth.uid() = user_id);


-- ------------------------------------------------------------
-- MATCH HISTORY
-- ------------------------------------------------------------
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

drop policy if exists "Users can view their own match history" on public.match_history;
create policy "Users can view their own match history"
  on public.match_history for select using (auth.uid() = user_id);

drop policy if exists "Users can insert their own match history" on public.match_history;
create policy "Users can insert their own match history"
  on public.match_history for insert with check (auth.uid() = user_id);


-- ------------------------------------------------------------
-- GAME SESSIONS - shared live state for REAL 2-player games
-- ------------------------------------------------------------
create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users (id) on delete cascade,
  player2_id uuid references public.users (id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  current_turn text not null default 'player1',
  status text not null default 'active'
    check (status in ('active', 'completed', 'abandoned')),
  winner_id uuid references public.users (id),
  entry_fee integer not null default 15,
  reward integer not null default 25,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists game_sessions_players_idx
  on public.game_sessions (player1_id, player2_id);

create index if not exists game_sessions_status_idx
  on public.game_sessions (status);

alter table public.game_sessions enable row level security;

drop policy if exists "Players can view their game sessions" on public.game_sessions;
create policy "Players can view their game sessions"
  on public.game_sessions for select
  using (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can insert their game sessions" on public.game_sessions;
create policy "Players can insert their game sessions"
  on public.game_sessions for insert
  with check (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can update their game sessions" on public.game_sessions;
create policy "Players can update their game sessions"
  on public.game_sessions for update
  using (auth.uid() = player1_id or auth.uid() = player2_id);

-- Enable realtime on game_sessions so both players get live updates.
do $$
begin
  begin
    alter publication supabase_realtime add table public.game_sessions;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;


-- ------------------------------------------------------------
-- AUTO-PROVISION NEW USERS - Welcome bonus ₹50
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (
    new.id, new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;

  insert into public.wallet (user_id, dummy_token)
  values (new.id, 50)  -- ₹50 welcome bonus
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ------------------------------------------------------------
-- CLAIM_OPPONENT
-- Pairs you with a genuinely-online waiting player and creates
-- a shared game_session both players can read/write in realtime.
-- Returns: { matched: bool, session_id, opponent_id, you_are }
-- ------------------------------------------------------------
create or replace function public.claim_opponent(
  p_game_type text,
  p_entry_fee integer default 15,
  p_reward integer default 25
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_opponent_id uuid;
  v_me uuid := auth.uid();
  v_session_id uuid;
begin
  -- purge stale queue entries (offline > 15s)
  delete from public.matchmaking_queue mq
  using public.users u
  where mq.user_id = u.id
    and mq.game_type = p_game_type
    and u.last_seen < now() - interval '15 seconds';

  -- pick a genuinely-online waiting opponent
  select mq.user_id into v_opponent_id
  from public.matchmaking_queue mq
  join public.users u on u.id = mq.user_id
  where mq.game_type = p_game_type
    and mq.user_id <> v_me
    and u.last_seen >= now() - interval '15 seconds'
  order by mq.created_at asc
  for update of mq skip locked
  limit 1;

  if v_opponent_id is null then
    return json_build_object('matched', false);
  end if;

  -- remove both from the queue
  delete from public.matchmaking_queue where user_id in (v_opponent_id, v_me);

  -- create the shared live session
  insert into public.game_sessions (
    game_type, player1_id, player2_id, state, current_turn,
    status, entry_fee, reward
  )
  values (
    p_game_type, v_opponent_id, v_me,
    '{}'::jsonb, 'player1', 'active', p_entry_fee, p_reward
  )
  returning id into v_session_id;

  return json_build_object(
    'matched', true,
    'session_id', v_session_id,
    'opponent_id', v_opponent_id,
    'you_are', 'player2'
  );
end;
$$;

grant execute on function public.claim_opponent(text, integer, integer) to authenticated;


-- ------------------------------------------------------------
-- REDEEM_REFERRAL_CODE - ₹50 for referrer and ₹50 for new user
-- ------------------------------------------------------------
create or replace function public.redeem_referral_code(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referrer_id uuid;
  v_me uuid := auth.uid();
  v_already uuid;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return json_build_object('success', false, 'message', 'Please enter a code.');
  end if;

  select referred_by into v_already from public.users where id = v_me;
  if v_already is not null then
    return json_build_object('success', false, 'message', 'You already redeemed a referral code.');
  end if;

  select id into v_referrer_id from public.users where referral_code = upper(trim(p_code));

  if v_referrer_id is null then
    return json_build_object('success', false, 'message', 'That referral code was not found.');
  end if;

  if v_referrer_id = v_me then
    return json_build_object('success', false, 'message', 'You cannot use your own referral code.');
  end if;

  update public.users set referred_by = v_referrer_id where id = v_me;

  -- ₹50 for new user, ₹50 for referrer
  update public.wallet set dummy_token = dummy_token + 50, updated_at = now() where user_id = v_me;
  update public.wallet set dummy_token = dummy_token + 50, updated_at = now() where user_id = v_referrer_id;

  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Referral bonus redeemed', 'credit', 50);

  insert into public.transactions (user_id, description, type, amount)
  values (v_referrer_id, 'Referral bonus: friend joined', 'credit', 50);

  return json_build_object('success', true, 'message', 'Referral applied! You received 50 tokens.');
end;
$$;

grant execute on function public.redeem_referral_code(text) to authenticated;


-- ------------------------------------------------------------
-- PAYMENT REQUESTS & AUTO-APPROVAL TRIGGER
-- ------------------------------------------------------------
create table if not exists public.payment_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  txn_id text not null unique,
  amount_inr numeric not null check (amount_inr > 0),
  tokens_to_credit integer not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

alter table public.payment_requests enable row level security;

drop policy if exists "Users can view own payments" on public.payment_requests;
create policy "Users can view own payments"
  on public.payment_requests for select using (auth.uid() = user_id);

drop policy if exists "Users can submit payment" on public.payment_requests;
create policy "Users can submit payment"
  on public.payment_requests for insert with check (auth.uid() = user_id);

drop policy if exists "Users can update own payments" on public.payment_requests;
create policy "Users can update own payments"
  on public.payment_requests for update using (auth.uid() = user_id);

create or replace function public.process_payment_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'approved' and old.status = 'pending' then
    update public.wallet
    set dummy_token = dummy_token + new.tokens_to_credit,
        updated_at = now()
    where user_id = new.user_id;

    insert into public.transactions (user_id, description, type, amount)
    values (new.user_id, 'Top-up: Paytm/UPI UTR ' || new.txn_id, 'credit', new.tokens_to_credit);

    new.reviewed_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists on_payment_approved on public.payment_requests;
create trigger on_payment_approved
  before update on public.payment_requests
  for each row execute procedure public.process_payment_approval();


-- ============================================================
-- v9 ADDITIONS — match invites (realtime), invite accept logic
-- ============================================================

-- ------------------------------------------------------------
-- MATCH INVITES
-- A lightweight realtime broadcast that a player is waiting in
-- queue, so others on the dashboard can join them within 5s.
-- ------------------------------------------------------------
create table if not exists public.match_invites (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null references public.users (id) on delete cascade,
  game_type text not null,
  game_name text not null,
  entry_fee integer not null default 15,
  reward integer not null default 25,
  status text not null default 'open'
    check (status in ('open', 'accepted', 'expired', 'cancelled')),
  accepted_by uuid references public.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '5 seconds')
);

create index if not exists match_invites_open_idx
  on public.match_invites (status, game_type, expires_at);

create index if not exists match_invites_from_idx
  on public.match_invites (from_user_id);

alter table public.match_invites enable row level security;

-- Anyone authenticated can see open invites (needed for the popup)
drop policy if exists "Open invites are visible" on public.match_invites;
create policy "Open invites are visible"
  on public.match_invites for select
  using (auth.role() = 'authenticated');

-- Only the creator can create an invite for themselves
drop policy if exists "Users can create their own invites" on public.match_invites;
create policy "Users can create their own invites"
  on public.match_invites for insert
  with check (auth.uid() = from_user_id);

-- Only the invite creator or the accepter can update
drop policy if exists "Users can update invites they created or accepted" on public.match_invites;
create policy "Users can update invites they created or accepted"
  on public.match_invites for update
  using (auth.uid() = from_user_id or auth.uid() = accepted_by);

-- Enable realtime on match_invites
do $$
begin
  begin
    alter publication supabase_realtime add table public.match_invites;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;


-- ------------------------------------------------------------
-- EXPIRE_OLD_INVITES
-- Flips any open invite past its expires_at to 'expired'.
-- Cheap to run; called by the client periodically.
-- ------------------------------------------------------------
create or replace function public.expire_old_invites()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.match_invites
  set status = 'expired'
  where status = 'open'
    and expires_at < now();
end;
$$;

grant execute on function public.expire_old_invites() to authenticated;


-- ------------------------------------------------------------
-- ACCEPT_MATCH_INVITE
-- Atomically accepts an open invite and creates the shared
-- game_session. Uses FOR UPDATE to prevent double-accept races.
-- Returns: { ok, session_id, opponent_id } or { ok:false, reason }
-- ------------------------------------------------------------
create or replace function public.accept_match_invite(p_invite_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.match_invites;
  v_session_id uuid;
begin
  -- Lock the row so two people can't both accept
  select * into v_invite from public.match_invites
  where id = p_invite_id
  for update;

  if v_invite is null then
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_invite.status <> 'open' then
    return json_build_object('ok', false, 'reason', 'already_taken');
  end if;
  if v_invite.expires_at < now() then
    update public.match_invites set status = 'expired' where id = p_invite_id;
    return json_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_invite.from_user_id = auth.uid() then
    return json_build_object('ok', false, 'reason', 'self');
  end if;

  -- Mark accepted
  update public.match_invites
  set status = 'accepted', accepted_by = auth.uid()
  where id = p_invite_id;

  -- Create the shared live game session
  insert into public.game_sessions (
    game_type, player1_id, player2_id, state, current_turn,
    status, entry_fee, reward
  )
  values (
    v_invite.game_type, v_invite.from_user_id, auth.uid(),
    '{}'::jsonb, 'player1', 'active',
    v_invite.entry_fee, v_invite.reward
  )
  returning id into v_session_id;

  return json_build_object(
    'ok', true,
    'session_id', v_session_id,
    'opponent_id', v_invite.from_user_id
  );
end;
$$;

grant execute on function public.accept_match_invite(uuid) to authenticated;


-- ============================================================
-- END OF SCHEMA v9
-- ============================================================
