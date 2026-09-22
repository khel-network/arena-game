-- ============================================================
-- SkillClash - MASTER SCHEMA v10.2 (₹-column safe + wallet realtime)
-- ============================================================
-- v10.2 change (vs v10.1):
--   * Added `alter publication supabase_realtime add table public.wallet`
--     inside a safe DO block. This enables the frontend's realtime
--     wallet subscription so the balance auto-updates across devices
--     when credit/debit happens (top-up, match win, admin approval).
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
-- WALLET (canonical `balance`; legacy `₹` handled dynamically)
-- ------------------------------------------------------------
create table if not exists public.wallet (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users (id) on delete cascade,
  balance integer not null default 25 check (balance >= 0),
  updated_at timestamptz not null default now()
);

alter table public.wallet add column if not exists balance integer;
alter table public.wallet add column if not exists email text;
alter table public.wallet add column if not exists full_name text;
alter table public.wallet add column if not exists first_login_at timestamptz not null default now();

do $$
declare
  v_has_rupee boolean;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if v_has_rupee then
    execute 'update public.wallet set balance = coalesce(balance, "₹", 0) where balance is null';
  else
    update public.wallet set balance = coalesce(balance, 0) where balance is null;
  end if;
end $$;

alter table public.wallet alter column balance set default 25;
alter table public.wallet alter column balance set not null;

do $$
begin
  begin
    alter table public.wallet add constraint wallet_balance_nonneg check (balance >= 0);
  exception
    when duplicate_object then null;
  end;
end $$;

update public.wallet w
set
  email = coalesce(w.email, u.email),
  full_name = coalesce(w.full_name, u.full_name),
  first_login_at = coalesce(w.first_login_at, w.updated_at, now())
from public.users u
where w.user_id = u.id
  and (w.email is null or w.full_name is null);

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


-- ============================================================
-- PART E — Enable realtime on wallet table
-- ============================================================
-- This allows the frontend's realtime subscription to receive
-- UPDATE events whenever wallet.balance changes (top-up,
-- match win/loss settlement, admin approval, refunds).
-- Without this, subscribeToWalletRealtime() will connect but
-- never receive any events.
-- ============================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.wallet;
  exception
    when duplicate_object then null;   -- already added, safe to ignore
    when undefined_object then null;   -- publication doesn't exist (older Supabase)
  end;
end $$;

-- Also ensure REPLICA IDENTITY is full so we get the full row
-- in the realtime payload (not just the primary key).
-- This is required for payload.new.balance to be present.
alter table public.wallet replica identity full;


-- ------------------------------------------------------------
-- SYNC TRIGGER: keep wallet.email / wallet.full_name in sync
-- ------------------------------------------------------------
create or replace function public.sync_wallet_from_users()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.wallet
  set
    email = new.email,
    full_name = new.full_name
  where user_id = new.id;
  return new;
end;
$$;

drop trigger if exists on_user_profile_updated on public.users;
create trigger on_user_profile_updated
  after update of email, full_name on public.users
  for each row execute procedure public.sync_wallet_from_users();


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
-- MATCHES (legacy, kept for compatibility)
-- ------------------------------------------------------------
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users (id),
  player2_id uuid not null references public.users (id),
  status text not null default 'active',
  winner_id uuid references public.users (id),
  entry_fee integer not null default 20,
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
-- TRANSACTIONS (ledger)
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
-- GAME SESSIONS
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
  entry_fee integer not null default 20,
  reward integer not null default 30,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.game_sessions add column if not exists stake_locked boolean not null default false;
alter table public.game_sessions add column if not exists abandoned_at timestamptz;
alter table public.game_sessions add column if not exists settled_at timestamptz;
alter table public.game_sessions add column if not exists settled_by uuid references public.users (id);

create index if not exists game_sessions_players_idx
  on public.game_sessions (player1_id, player2_id);

create index if not exists game_sessions_status_idx
  on public.game_sessions (status);

create index if not exists game_sessions_game_type_status_idx
  on public.game_sessions (game_type, status);

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
-- GAME EVENTS (audit trail)
-- ------------------------------------------------------------
create table if not exists public.game_events (
  id bigserial primary key,
  session_id uuid references public.game_sessions (id) on delete cascade,
  user_id uuid references public.users (id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists game_events_session_idx
  on public.game_events (session_id, created_at desc);

alter table public.game_events enable row level security;

drop policy if exists "Players can view events for their sessions" on public.game_events;
create policy "Players can view events for their sessions"
  on public.game_events for select
  using (
    exists (
      select 1 from public.game_sessions gs
      where gs.id = game_events.session_id
        and (gs.player1_id = auth.uid() or gs.player2_id = auth.uid())
    )
  );

drop policy if exists "Authenticated can insert events" on public.game_events;
create policy "Authenticated can insert events"
  on public.game_events for insert
  with check (auth.role() = 'authenticated');


-- ------------------------------------------------------------
-- AUTO-PROVISION NEW USERS — ₹25 welcome bonus
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_rupee boolean;
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (
    new.id, new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if v_has_rupee then
    execute $sql$
      insert into public.wallet (user_id, balance, "₹", email, full_name, first_login_at)
      values ($1, 25, 25, $2, $3, now())
      on conflict (user_id) do nothing
    $sql$ using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  else
    execute $sql$
      insert into public.wallet (user_id, balance, email, full_name, first_login_at)
      values ($1, 25, $2, $3, now())
      on conflict (user_id) do nothing
    $sql$ using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (new.id, 'Welcome bonus', 'credit', 25)
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ------------------------------------------------------------
-- CLAIM_OPPONENT
-- ------------------------------------------------------------
create or replace function public.claim_opponent(
  p_game_type text,
  p_entry_fee integer default 20,
  p_reward integer default 30
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
  if v_me is null then
    return json_build_object('matched', false, 'reason', 'not_authenticated');
  end if;

  delete from public.matchmaking_queue mq
  using public.users u
  where mq.user_id = u.id
    and mq.game_type = p_game_type
    and u.last_seen < now() - interval '25 seconds';

  select mq.user_id into v_opponent_id
  from public.matchmaking_queue mq
  join public.users u on u.id = mq.user_id
  where mq.game_type = p_game_type
    and mq.user_id <> v_me
    and u.last_seen >= now() - interval '25 seconds'
  order by mq.created_at asc
  for update of mq skip locked
  limit 1;

  if v_opponent_id is null then
    return json_build_object('matched', false);
  end if;

  delete from public.matchmaking_queue where user_id in (v_opponent_id, v_me);

  insert into public.game_sessions (
    game_type, player1_id, player2_id, state, current_turn,
    status, entry_fee, reward, stake_locked
  )
  values (
    p_game_type, v_opponent_id, v_me,
    '{}'::jsonb, 'player1', 'active', p_entry_fee, p_reward, true
  )
  returning id into v_session_id;

  insert into public.game_events (session_id, user_id, event_type, payload)
  values (
    v_session_id, v_me, 'match_created',
    jsonb_build_object('opponent', v_opponent_id, 'game', p_game_type)
  );

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
-- REDEEM_REFERRAL_CODE
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
  v_bonus constant integer := 25;
  v_has_rupee boolean;
begin
  if v_me is null then
    return json_build_object('success', false, 'message', 'Not authenticated.');
  end if;

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

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if v_has_rupee then
    update public.wallet
      set balance = balance + v_bonus,
          "₹" = "₹" + v_bonus,
          updated_at = now()
      where user_id = v_me;
    update public.wallet
      set balance = balance + v_bonus,
          "₹" = "₹" + v_bonus,
          updated_at = now()
      where user_id = v_referrer_id;
  else
    update public.wallet set balance = balance + v_bonus, updated_at = now() where user_id = v_me;
    update public.wallet set balance = balance + v_bonus, updated_at = now() where user_id = v_referrer_id;
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Referral bonus redeemed', 'credit', v_bonus);

  insert into public.transactions (user_id, description, type, amount)
  values (v_referrer_id, 'Referral bonus: friend joined', 'credit', v_bonus);

  return json_build_object('success', true,
    'message', 'Referral applied! You received ₹' || v_bonus || '.');
end;
$$;

grant execute on function public.redeem_referral_code(text) to authenticated;


-- ------------------------------------------------------------
-- PAYMENT REQUESTS & AUTO-APPROVAL
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
declare
  v_has_rupee boolean;
begin
  if new.status = 'approved' and old.status = 'pending' then
    select exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
    ) into v_has_rupee;

    if v_has_rupee then
      update public.wallet
      set balance = balance + new.tokens_to_credit,
          "₹" = "₹" + new.tokens_to_credit,
          updated_at = now()
      where user_id = new.user_id;
    else
      update public.wallet
      set balance = balance + new.tokens_to_credit,
          updated_at = now()
      where user_id = new.user_id;
    end if;

    insert into public.transactions (user_id, description, type, amount)
    values (new.user_id, 'Top-up: UTR ' || new.txn_id, 'credit', new.tokens_to_credit);

    new.reviewed_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists on_payment_approved on public.payment_requests;
create trigger on_payment_approved
  before update on public.payment_requests
  for each row execute procedure public.process_payment_approval();


-- ------------------------------------------------------------
-- MATCH INVITES
-- ------------------------------------------------------------
create table if not exists public.match_invites (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null references public.users (id) on delete cascade,
  game_type text not null,
  game_name text not null,
  entry_fee integer not null default 20,
  reward integer not null default 30,
  status text not null default 'open'
    check (status in ('open', 'accepted', 'expired', 'cancelled')),
  accepted_by uuid references public.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '12 seconds')
);

alter table public.match_invites
  alter column expires_at set default (now() + interval '12 seconds');

create index if not exists match_invites_open_idx
  on public.match_invites (status, game_type, expires_at);

create index if not exists match_invites_from_idx
  on public.match_invites (from_user_id);

alter table public.match_invites enable row level security;

drop policy if exists "Open invites are visible" on public.match_invites;
create policy "Open invites are visible"
  on public.match_invites for select
  using (auth.role() = 'authenticated');

drop policy if exists "Users can create their own invites" on public.match_invites;
create policy "Users can create their own invites"
  on public.match_invites for insert
  with check (auth.uid() = from_user_id);

drop policy if exists "Users can update invites they created or accepted" on public.match_invites;
create policy "Users can update invites they created or accepted"
  on public.match_invites for update
  using (auth.uid() = from_user_id or auth.uid() = accepted_by);

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
  v_me uuid := auth.uid();
begin
  if v_me is null then
    return json_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

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
  if v_invite.from_user_id = v_me then
    return json_build_object('ok', false, 'reason', 'self');
  end if;

  update public.match_invites
  set status = 'accepted', accepted_by = v_me
  where id = p_invite_id;

  insert into public.game_sessions (
    game_type, player1_id, player2_id, state, current_turn,
    status, entry_fee, reward, stake_locked
  )
  values (
    v_invite.game_type, v_invite.from_user_id, v_me,
    '{}'::jsonb, 'player1', 'active',
    v_invite.entry_fee, v_invite.reward, true
  )
  returning id into v_session_id;

  insert into public.game_events (session_id, user_id, event_type, payload)
  values (
    v_session_id, v_me, 'invite_accepted',
    jsonb_build_object('invite_id', p_invite_id, 'opponent', v_invite.from_user_id)
  );

  return json_build_object(
    'ok', true,
    'session_id', v_session_id,
    'opponent_id', v_invite.from_user_id
  );
end;
$$;

grant execute on function public.accept_match_invite(uuid) to authenticated;


-- ============================================================
-- Settlement RPCs
-- ============================================================

create or replace function public.end_session_with_state(
  p_session_id uuid,
  p_final_state jsonb default '{}'::jsonb,
  p_winner_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.game_sessions;
  v_me uuid := auth.uid();
  v_is_player boolean;
  v_entry integer;
  v_reward integer;
  v_has_rupee boolean;
begin
  if v_me is null then
    return json_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  select * into v_session from public.game_sessions
  where id = p_session_id
  for update;

  if v_session is null then
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;

  v_is_player := (v_session.player1_id = v_me or v_session.player2_id = v_me);
  if not v_is_player then
    return json_build_object('ok', false, 'reason', 'not_a_player');
  end if;

  if v_session.status <> 'active' then
    return json_build_object('ok', true, 'already_settled', true,
      'winner_id', v_session.winner_id, 'status', v_session.status);
  end if;

  if p_winner_id is not null
     and p_winner_id <> v_session.player1_id
     and p_winner_id <> v_session.player2_id then
    p_winner_id := null;
  end if;

  update public.game_sessions
  set
    status = 'completed',
    state = coalesce(p_final_state, state),
    winner_id = p_winner_id,
    settled_at = now(),
    settled_by = v_me,
    updated_at = now()
  where id = p_session_id;

  v_entry := v_session.entry_fee;
  v_reward := v_session.reward;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if p_winner_id is not null then
    if v_has_rupee then
      execute $sql$
        update public.wallet
        set balance = balance + $1, "₹" = "₹" + $1, updated_at = now()
        where user_id = $2
      $sql$ using v_reward, p_winner_id;
    else
      update public.wallet
      set balance = balance + v_reward, updated_at = now()
      where user_id = p_winner_id;
    end if;

    insert into public.transactions (user_id, description, type, amount)
    values (p_winner_id, 'Duel Victory — ' || v_session.game_type, 'credit', v_reward);

    insert into public.match_history (user_id, game, opponent, result, reward)
    select p_winner_id, v_session.game_type,
           coalesce(u.full_name, 'Opponent'), 'VICTORY', v_reward
    from public.users u
    where u.id = case
      when v_session.player1_id = p_winner_id then v_session.player2_id
      else v_session.player1_id
    end;

    insert into public.match_history (user_id, game, opponent, result, reward)
    select case when v_session.player1_id = p_winner_id then v_session.player2_id
                else v_session.player1_id end,
           v_session.game_type,
           coalesce(u.full_name, 'Opponent'),
           'DEFEAT', -v_entry
    from public.users u
    where u.id = p_winner_id;
  else
    if v_has_rupee then
      execute $sql$
        update public.wallet
        set balance = balance + $1, "₹" = "₹" + $1, updated_at = now()
        where user_id in ($2, $3)
      $sql$ using v_entry, v_session.player1_id, v_session.player2_id;
    else
      update public.wallet
      set balance = balance + v_entry, updated_at = now()
      where user_id in (v_session.player1_id, v_session.player2_id);
    end if;

    insert into public.transactions (user_id, description, type, amount)
    values (v_session.player1_id, 'Draw refund — ' || v_session.game_type, 'credit', v_entry);

    insert into public.transactions (user_id, description, type, amount)
    values (v_session.player2_id, 'Draw refund — ' || v_session.game_type, 'credit', v_entry);

    insert into public.match_history (user_id, game, opponent, result, reward)
    values (v_session.player1_id, v_session.game_type, 'Opponent', 'DRAW', 0),
           (v_session.player2_id, v_session.game_type, 'Opponent', 'DRAW', 0);
  end if;

  insert into public.game_events (session_id, user_id, event_type, payload)
  values (p_session_id, v_me, 'session_ended',
    jsonb_build_object('winner_id', p_winner_id, 'settled_by', v_me));

  return json_build_object('ok', true, 'winner_id', p_winner_id, 'status', 'completed');
end;
$$;

grant execute on function public.end_session_with_state(uuid, jsonb, uuid) to authenticated;


create or replace function public.abandon_session(p_session_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.game_sessions;
  v_me uuid := auth.uid();
  v_opponent uuid;
  v_has_rupee boolean;
begin
  if v_me is null then
    return json_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  select * into v_session from public.game_sessions
  where id = p_session_id for update;

  if v_session is null then
    return json_build_object('ok', false, 'reason', 'not_found');
  end if;

  if v_me <> v_session.player1_id and v_me <> v_session.player2_id then
    return json_build_object('ok', false, 'reason', 'not_a_player');
  end if;

  if v_session.status <> 'active' then
    return json_build_object('ok', true, 'already_settled', true);
  end if;

  v_opponent := case    when v_me = v_session.player1_id then v_session.player2_id
    else v_session.player1_id
  end;

  update public.game_sessions
  set status = 'abandoned',
      winner_id = v_opponent,
      abandoned_at = now(),
      settled_at = now(),
      settled_by = v_me,
      updated_at = now()
  where id = p_session_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if v_opponent is not null then
    if v_has_rupee then
      execute $sql$
        update public.wallet
        set balance = balance + $1, "₹" = "₹" + $1, updated_at = now()
        where user_id = $2
      $sql$ using v_session.reward, v_opponent;
    else
      update public.wallet set balance = balance + v_session.reward, updated_at = now()
      where user_id = v_opponent;
    end if;

    insert into public.transactions (user_id, description, type, amount)
    values (v_opponent, 'Opponent abandoned — ' || v_session.game_type, 'credit', v_session.reward);

    insert into public.match_history (user_id, game, opponent, result, reward)
    values (v_opponent, v_session.game_type, 'Opponent', 'VICTORY', v_session.reward);
  end if;

  insert into public.match_history (user_id, game, opponent, result, reward)
  values (v_me, v_session.game_type, 'Opponent', 'DEFEAT', -v_session.entry_fee);

  insert into public.game_events (session_id, user_id, event_type, payload)
  values (p_session_id, v_me, 'session_abandoned', jsonb_build_object('opponent', v_opponent));

  return json_build_object('ok', true, 'winner_id', v_opponent);
end;
$$;

grant execute on function public.abandon_session(uuid) to authenticated;


create or replace function public.refund_stake_on_no_opponent(
  p_game_type text,
  p_entry_fee integer
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_has_rupee boolean;
begin
  if v_me is null then
    return json_build_object('ok', false, 'reason', 'not_authenticated');
  end if;

  delete from public.matchmaking_queue where user_id = v_me and game_type = p_game_type;

  update public.match_invites
  set status = 'cancelled'
  where from_user_id = v_me and game_type = p_game_type and status = 'open';

  select exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'wallet' and column_name = '₹'
  ) into v_has_rupee;

  if v_has_rupee then
    execute $sql$
      update public.wallet
      set balance = balance + $1, "₹" = "₹" + $1, updated_at = now()
      where user_id = $2
    $sql$ using p_entry_fee, v_me;
  else
    update public.wallet set balance = balance + p_entry_fee, updated_at = now()
    where user_id = v_me;
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Stake refund — no opponent found (' || p_game_type || ')', 'credit', p_entry_fee);

  return json_build_object('ok', true, 'refunded', p_entry_fee);
end;
$$;

grant execute on function public.refund_stake_on_no_opponent(text, integer) to authenticated;


-- ============================================================
-- END OF SCHEMA v10.2
-- ============================================================
