-- ============================================================
-- SkillClash - MASTER SCHEMA v11.0
-- ============================================================
-- v11.0 changes vs v10.3:
--   * matchmaking_queue: added device_fp + last_ip columns
--   * claim_opponent: blocks same email + same username pattern
--     + same device + same IP + max 2 lifetime matches per pair
--   * NEW: notifications table with realtime + admin RPCs
--   * NEW RPC: send_notification (broadcast or targeted)
--   * NEW RPC: mark_notifications_read
--   * NEW: admin_notifications_view
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
  on public.users for select using (auth.role() = 'authenticated');

drop policy if exists "Users can update their own profile" on public.users;
create policy "Users can update their own profile"
  on public.users for update using (auth.uid() = id);

drop policy if exists "Users can insert their own profile" on public.users;
create policy "Users can insert their own profile"
  on public.users for insert with check (auth.uid() = id);


-- ------------------------------------------------------------
-- WALLET
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
declare v_has_rupee boolean;
begin
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
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
  exception when duplicate_object then null;
  end;
end $$;

update public.wallet w
set email = coalesce(w.email, u.email),
    full_name = coalesce(w.full_name, u.full_name),
    first_login_at = coalesce(w.first_login_at, w.updated_at, now())
from public.users u
where w.user_id = u.id and (w.email is null or w.full_name is null);

alter table public.wallet enable row level security;
drop policy if exists "Users can view their own wallet" on public.wallet;
create policy "Users can view their own wallet" on public.wallet for select using (auth.uid() = user_id);
drop policy if exists "Users can update their own wallet" on public.wallet;
create policy "Users can update their own wallet" on public.wallet for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "Users can insert their own wallet" on public.wallet;
create policy "Users can insert their own wallet" on public.wallet for insert with check (auth.uid() = user_id);

do $$ begin begin alter publication supabase_realtime add table public.wallet; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.wallet replica identity full;


-- ------------------------------------------------------------
-- SYNC TRIGGER
-- ------------------------------------------------------------
create or replace function public.sync_wallet_from_users()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.wallet set email = new.email, full_name = new.full_name where user_id = new.id;
  return new;
end; $$;

drop trigger if exists on_user_profile_updated on public.users;
create trigger on_user_profile_updated after update of email, full_name on public.users
  for each row execute procedure public.sync_wallet_from_users();


-- ------------------------------------------------------------
-- MATCHMAKING QUEUE (with device fingerprint + IP)
-- ------------------------------------------------------------
create table if not exists public.matchmaking_queue (
  user_id uuid primary key references public.users (id) on delete cascade,
  game_type text not null,
  created_at timestamptz not null default now()
);

alter table public.matchmaking_queue add column if not exists device_fp text;
alter table public.matchmaking_queue add column if not exists last_ip text;
alter table public.matchmaking_queue add column if not exists last_email text;
alter table public.matchmaking_queue add column if not exists last_username text;

alter table public.matchmaking_queue enable row level security;
drop policy if exists "Users can see the queue" on public.matchmaking_queue;
create policy "Users can see the queue" on public.matchmaking_queue for select using (true);
drop policy if exists "Users can join the queue as themselves" on public.matchmaking_queue;
create policy "Users can join the queue as themselves" on public.matchmaking_queue for insert with check (auth.uid() = user_id);
drop policy if exists "Users can leave the queue" on public.matchmaking_queue;
create policy "Users can leave the queue" on public.matchmaking_queue for delete using (auth.uid() = user_id);


-- ------------------------------------------------------------
-- MATCHES (legacy)
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
create policy "Players can view their own matches" on public.matches for select using (auth.uid() = player1_id or auth.uid() = player2_id);
drop policy if exists "Players can create a match they are part of" on public.matches;
create policy "Players can create a match they are part of" on public.matches for insert with check (auth.uid() = player1_id or auth.uid() = player2_id);
drop policy if exists "Players can update their own matches" on public.matches;
create policy "Players can update their own matches" on public.matches for update using (auth.uid() = player1_id or auth.uid() = player2_id);


-- ------------------------------------------------------------
-- TRANSACTIONS
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
create policy "Users can view their own transactions" on public.transactions for select using (auth.uid() = user_id);
drop policy if exists "Users can insert their own transactions" on public.transactions;
create policy "Users can insert their own transactions" on public.transactions for insert with check (auth.uid() = user_id);


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
create policy "Users can view their own match history" on public.match_history for select using (auth.uid() = user_id);
drop policy if exists "Users can insert their own match history" on public.match_history;
create policy "Users can insert their own match history" on public.match_history for insert with check (auth.uid() = user_id);


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
  status text not null default 'active' check (status in ('active', 'completed', 'abandoned')),
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

create index if not exists game_sessions_players_idx on public.game_sessions (player1_id, player2_id);
create index if not exists game_sessions_status_idx on public.game_sessions (status);
create index if not exists game_sessions_game_type_status_idx on public.game_sessions (game_type, status);

alter table public.game_sessions enable row level security;
drop policy if exists "Players can view their game sessions" on public.game_sessions;
create policy "Players can view their game sessions" on public.game_sessions for select using (auth.uid() = player1_id or auth.uid() = player2_id);
drop policy if exists "Players can insert their game sessions" on public.game_sessions;
create policy "Players can insert their game sessions" on public.game_sessions for insert with check (auth.uid() = player1_id or auth.uid() = player2_id);
drop policy if exists "Players can update their game sessions" on public.game_sessions;
create policy "Players can update their game sessions" on public.game_sessions for update using (auth.uid() = player1_id or auth.uid() = player2_id);

do $$ begin begin alter publication supabase_realtime add table public.game_sessions; exception when duplicate_object then null; when undefined_object then null; end; end $$;


-- ------------------------------------------------------------
-- GAME EVENTS
-- ------------------------------------------------------------
create table if not exists public.game_events (
  id bigserial primary key,
  session_id uuid references public.game_sessions (id) on delete cascade,
  user_id uuid references public.users (id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists game_events_session_idx on public.game_events (session_id, created_at desc);
alter table public.game_events enable row level security;
drop policy if exists "Players can view events for their sessions" on public.game_events;
create policy "Players can view events for their sessions" on public.game_events for select using (
  exists (select 1 from public.game_sessions gs where gs.id = game_events.session_id and (gs.player1_id = auth.uid() or gs.player2_id = auth.uid()))
);
drop policy if exists "Authenticated can insert events" on public.game_events;
create policy "Authenticated can insert events" on public.game_events for insert with check (auth.role() = 'authenticated');


-- ------------------------------------------------------------
-- AUTO-PROVISION NEW USERS (welcome bonus + welcome notification)
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_has_rupee boolean;
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'avatar_url')
  on conflict (id) do nothing;

  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;

  if v_has_rupee then
    execute $sql$ insert into public.wallet (user_id, balance, "₹", email, full_name, first_login_at) values ($1, 25, 25, $2, $3, now()) on conflict (user_id) do nothing $sql$
    using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  else
    execute $sql$ insert into public.wallet (user_id, balance, email, full_name, first_login_at) values ($1, 25, $2, $3, now()) on conflict (user_id) do nothing $sql$
    using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (new.id, 'Welcome bonus', 'credit', 25);

  -- welcome notification (deferred until notifications table exists)
  begin
    insert into public.notifications (user_id, title, body, type, icon)
    values (new.id, 'Welcome to SkillClash!', 'You received ₹25 welcome bonus. Play your first match now!', 'welcome', 'gift');
  exception when undefined_table then null;
  end;

  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute procedure public.handle_new_user();


-- ------------------------------------------------------------
-- CLAIM_OPPONENT (v11.0 — anti-farm hardened)
-- ------------------------------------------------------------
create or replace function public.claim_opponent(
  p_game_type text,
  p_entry_fee integer default 20,
  p_reward integer default 30,
  p_my_ip text default null,
  p_my_device_fp text default null
)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_opponent_id uuid;
  v_me uuid := auth.uid();
  v_session_id uuid;
  v_my_email text;
  v_my_username text;
  v_opp_email text;
  v_opp_username text;
  v_pair_lifetime integer;
begin
  if v_me is null then
    return json_build_object('matched', false, 'reason', 'not_authenticated');
  end if;

  -- my info
  select email, full_name into v_my_email, v_my_username from public.users where id = v_me;
  v_my_email := lower(coalesce(v_my_email, ''));
  v_my_username := lower(regexp_replace(coalesce(v_my_username, ''), '[^a-zA-Z0-9]', '', 'g'));

  -- purge stale queue entries
  delete from public.matchmaking_queue mq
  using public.users u
  where mq.user_id = u.id
    and mq.game_type = p_game_type
    and u.last_seen < now() - interval '25 seconds';

  -- find candidate: same game, online, not me, not same email, not same username, not same device, not same IP, and <2 lifetime matches
  select mq.user_id into v_opponent_id
  from public.matchmaking_queue mq
  join public.users u on u.id = mq.user_id
  where mq.game_type = p_game_type
    and mq.user_id <> v_me
    and u.last_seen >= now() - interval '25 seconds'

    -- email similarity
    and lower(coalesce(u.email, '')) <> v_my_email
    and lower(regexp_replace(coalesce(u.full_name, ''), '[^a-zA-Z0-9]', '', 'g')) <> v_my_username

    -- device / IP
    and (p_my_device_fp is null or mq.device_fp is null or mq.device_fp <> p_my_device_fp)
    and (p_my_ip is null or mq.last_ip is null or mq.last_ip <> p_my_ip)

    -- lifetime cap between this exact pair (max 2 matches)
    and (
      select count(*) from public.game_sessions gs
      where gs.game_type = p_game_type
        and (
          (gs.player1_id = mq.user_id and gs.player2_id = v_me)
          or (gs.player1_id = v_me and gs.player2_id = mq.user_id)
        )
    ) < 2
  order by mq.created_at asc
  for update of mq skip locked
  limit 1;

  if v_opponent_id is null then
    return json_build_object('matched', false);
  end if;

  -- double check: same person but different email?
  select email, full_name into v_opp_email, v_opp_username from public.users where id = v_opponent_id;
  v_opp_email := lower(coalesce(v_opp_email, ''));
  v_opp_username := lower(regexp_replace(coalesce(v_opp_username, ''), '[^a-zA-Z0-9]', '', 'g'));

  -- if usernames share a strong prefix (>=5 chars), flag
  if length(v_my_username) >= 5 and length(v_opp_username) >= 5 then
    if substring(v_my_username from 1 for 5) = substring(v_opp_username from 1 for 5) then
      -- silently exclude (same person, different email)
      return json_build_object('matched', false, 'reason', 'similar_user_blocked');
    end if;
  end if;

  -- create session
  delete from public.matchmaking_queue where user_id in (v_opponent_id, v_me);

  insert into public.game_sessions (
    game_type, player1_id, player2_id, state, current_turn, status, entry_fee, reward, stake_locked
  )
  values (
    p_game_type, v_opponent_id, v_me,
    '{}'::jsonb, 'player1', 'active', p_entry_fee, p_reward, true
  )
  returning id into v_session_id;

  insert into public.game_events (session_id, user_id, event_type, payload)
  values (v_session_id, v_me, 'match_created', jsonb_build_object('opponent', v_opponent_id, 'game', p_game_type));

  return json_build_object(
    'matched', true,
    'session_id', v_session_id,
    'opponent_id', v_opponent_id,
    'you_are', 'player2'
  );
end; $$;

grant execute on function public.claim_opponent(text, integer, integer, text, text) to authenticated;


-- ------------------------------------------------------------
-- REDEEM_REFERRAL_CODE
-- ------------------------------------------------------------
create or replace function public.redeem_referral_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_referrer_id uuid; v_me uuid := auth.uid(); v_already uuid;
  v_bonus constant integer := 25; v_has_rupee boolean;
begin
  if v_me is null then return json_build_object('success', false, 'message', 'Not authenticated.'); end if;
  if p_code is null or length(trim(p_code)) = 0 then return json_build_object('success', false, 'message', 'Please enter a code.'); end if;
  select referred_by into v_already from public.users where id = v_me;
  if v_already is not null then return json_build_object('success', false, 'message', 'You already redeemed a referral code.'); end if;
  select id into v_referrer_id from public.users where referral_code = upper(trim(p_code));
  if v_referrer_id is null then return json_build_object('success', false, 'message', 'That referral code was not found.'); end if;
  if v_referrer_id = v_me then return json_build_object('success', false, 'message', 'You cannot use your own referral code.'); end if;
  update public.users set referred_by = v_referrer_id where id = v_me;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_has_rupee then
    update public.wallet set balance = balance + v_bonus, "₹" = "₹" + v_bonus, updated_at = now() where user_id = v_me;
    update public.wallet set balance = balance + v_bonus, "₹" = "₹" + v_bonus, updated_at = now() where user_id = v_referrer_id;
  else
    update public.wallet set balance = balance + v_bonus, updated_at = now() where user_id = v_me;
    update public.wallet set balance = balance + v_bonus, updated_at = now() where user_id = v_referrer_id;
  end if;
  insert into public.transactions (user_id, description, type, amount) values (v_me, 'Referral bonus redeemed', 'credit', v_bonus);
  insert into public.transactions (user_id, description, type, amount) values (v_referrer_id, 'Referral bonus: friend joined', 'credit', v_bonus);
  return json_build_object('success', true, 'message', 'Referral applied! You received ₹' || v_bonus || '.');
end; $$;

grant execute on function public.redeem_referral_code(text) to authenticated;


-- ------------------------------------------------------------
-- PAYMENT REQUESTS
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
create policy "Users can view own payments" on public.payment_requests for select using (auth.uid() = user_id);
drop policy if exists "Users can submit payment" on public.payment_requests;
create policy "Users can submit payment" on public.payment_requests for insert with check (auth.uid() = user_id);
drop policy if exists "Users can update own payments" on public.payment_requests;
create policy "Users can update own payments" on public.payment_requests for update using (auth.uid() = user_id);

create or replace function public.process_payment_approval()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_has_rupee boolean;
begin
  if new.status = 'approved' and old.status = 'pending' then
    select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
    if v_has_rupee then
      update public.wallet set balance = balance + new.tokens_to_credit, "₹" = "₹" + new.tokens_to_credit, updated_at = now() where user_id = new.user_id;
    else
      update public.wallet set balance = balance + new.tokens_to_credit, updated_at = now() where user_id = new.user_id;
    end if;
    insert into public.transactions (user_id, description, type, amount)
    values (new.user_id, 'Top-up: UTR ' || new.txn_id, 'credit', new.tokens_to_credit);
    new.reviewed_at = now();
  end if;
  return new;
end; $$;

drop trigger if exists on_payment_approved on public.payment_requests;
create trigger on_payment_approved before update on public.payment_requests
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
  status text not null default 'open' check (status in ('open', 'accepted', 'expired', 'cancelled')),
  accepted_by uuid references public.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '12 seconds')
);
alter table public.match_invites alter column expires_at set default (now() + interval '12 seconds');
create index if not exists match_invites_open_idx on public.match_invites (status, game_type, expires_at);
create index if not exists match_invites_from_idx on public.match_invites (from_user_id);
alter table public.match_invites enable row level security;
drop policy if exists "Open invites are visible" on public.match_invites;
create policy "Open invites are visible" on public.match_invites for select using (auth.role() = 'authenticated');
drop policy if exists "Users can create their own invites" on public.match_invites;
create policy "Users can create their own invites" on public.match_invites for insert with check (auth.uid() = from_user_id);
drop policy if exists "Users can update invites they created or accepted" on public.match_invites;
create policy "Users can update invites they created or accepted" on public.match_invites for update using (auth.uid() = from_user_id or auth.uid() = accepted_by);

do $$ begin begin alter publication supabase_realtime add table public.match_invites; exception when duplicate_object then null; when undefined_object then null; end; end $$;


create or replace function public.expire_old_invites()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.match_invites set status = 'expired' where status = 'open' and expires_at < now();
end; $$;
grant execute on function public.expire_old_invites() to authenticated;


create or replace function public.accept_match_invite(p_invite_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_invite public.match_invites; v_session_id uuid; v_me uuid := auth.uid();
begin
  if v_me is null then return json_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  select * into v_invite from public.match_invites where id = p_invite_id for update;
  if v_invite is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_invite.status <> 'open' then return json_build_object('ok', false, 'reason', 'already_taken'); end if;
  if v_invite.expires_at < now() then update public.match_invites set status = 'expired' where id = p_invite_id; return json_build_object('ok', false, 'reason', 'expired'); end if;
  if v_invite.from_user_id = v_me then return json_build_object('ok', false, 'reason', 'self'); end if;
  update public.match_invites set status = 'accepted', accepted_by = v_me where id = p_invite_id;
  insert into public.game_sessions (game_type, player1_id, player2_id, state, current_turn, status, entry_fee, reward, stake_locked)
  values (v_invite.game_type, v_invite.from_user_id, v_me, '{}'::jsonb, 'player1', 'active', v_invite.entry_fee, v_invite.reward, true)
  returning id into v_session_id;
  insert into public.game_events (session_id, user_id, event_type, payload)
  values (v_session_id, v_me, 'invite_accepted', jsonb_build_object('invite_id', p_invite_id, 'opponent', v_invite.from_user_id));
  return json_build_object('ok', true, 'session_id', v_session_id, 'opponent_id', v_invite.from_user_id);
end; $$;
grant execute on function public.accept_match_invite(uuid) to authenticated;


-- ------------------------------------------------------------
-- SETTLEMENT RPCs (end_session_with_state, abandon_session, refund_stake_on_no_opponent)
-- ------------------------------------------------------------
create or replace function public.end_session_with_state(
  p_session_id uuid, p_final_state jsonb default '{}'::jsonb, p_winner_id uuid default null
)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_session public.game_sessions; v_me uuid := auth.uid(); v_is_player boolean;
  v_entry integer; v_reward integer; v_has_rupee boolean;
begin
  if v_me is null then return json_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  select * into v_session from public.game_sessions where id = p_session_id for update;
  if v_session is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  v_is_player := (v_session.player1_id = v_me or v_session.player2_id = v_me);
  if not v_is_player then return json_build_object('ok', false, 'reason', 'not_a_player'); end if;
  if v_session.status <> 'active' then
    return json_build_object('ok', true, 'already_settled', true, 'winner_id', v_session.winner_id, 'status', v_session.status);
  end if;
  if p_winner_id is not null and p_winner_id <> v_session.player1_id and p_winner_id <> v_session.player2_id then
    p_winner_id := null;
  end if;
  update public.game_sessions set status='completed', state=coalesce(p_final_state,state), winner_id=p_winner_id,
    settled_at=now(), settled_by=v_me, updated_at=now() where id = p_session_id;
  v_entry := v_session.entry_fee; v_reward := v_session.reward;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if p_winner_id is not null then
    if v_has_rupee then
      execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id = $2 $sql$ using v_reward, p_winner_id;
    else
      update public.wallet set balance = balance + v_reward, updated_at = now() where user_id = p_winner_id;
    end if;
    insert into public.transactions (user_id, description, type, amount)
    values (p_winner_id, 'Duel Victory — ' || v_session.game_type, 'credit', v_reward);
    insert into public.match_history (user_id, game, opponent, result, reward)
    select p_winner_id, v_session.game_type, coalesce(u.full_name, 'Opponent'), 'VICTORY', v_reward
    from public.users u where u.id = case when v_session.player1_id = p_winner_id then v_session.player2_id else v_session.player1_id end;
    insert into public.match_history (user_id, game, opponent, result, reward)
    select case when v_session.player1_id = p_winner_id then v_session.player2_id else v_session.player1_id end,
           v_session.game_type, coalesce(u.full_name, 'Opponent'), 'DEFEAT', -v_entry
    from public.users u where u.id = p_winner_id;
  else
    if v_has_rupee then
      execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id in ($2, $3) $sql$ using v_entry, v_session.player1_id, v_session.player2_id;
    else
      update public.wallet set balance = balance + v_entry, updated_at = now() where user_id in (v_session.player1_id, v_session.player2_id);
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
  values (p_session_id, v_me, 'session_ended', jsonb_build_object('winner_id', p_winner_id, 'settled_by', v_me));
  return json_build_object('ok', true, 'winner_id', p_winner_id, 'status', 'completed');
end; $$;
grant execute on function public.end_session_with_state(uuid, jsonb, uuid) to authenticated;


create or replace function public.abandon_session(p_session_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_session public.game_sessions; v_me uuid := auth.uid(); v_opponent uuid; v_has_rupee boolean;
begin
  if v_me is null then return json_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  select * into v_session from public.game_sessions where id = p_session_id for update;
  if v_session is null then return json_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_me <> v_session.player1_id and v_me <> v_session.player2_id then return json_build_object('ok', false, 'reason', 'not_a_player'); end if;
  if v_session.status <> 'active' then return json_build_object('ok', true, 'already_settled', true); end if;
  v_opponent := case when v_me = v_session.player1_id then v_session.player2_id else v_session.player1_id end;
  update public.game_sessions set status='abandoned', winner_id=v_opponent, abandoned_at=now(),
    settled_at=now(), settled_by=v_me, updated_at=now() where id = p_session_id;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_opponent is not null then
    if v_has_rupee then
      execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id = $2 $sql$ using v_session.reward, v_opponent;
    else
      update public.wallet set balance = balance + v_session.reward, updated_at = now() where user_id = v_opponent;
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
end; $$;
grant execute on function public.abandon_session(uuid) to authenticated;


create or replace function public.refund_stake_on_no_opponent(
  p_game_type text, p_entry_fee integer
)
returns json language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_has_rupee boolean;
begin
  if v_me is null then return json_build_object('ok', false, 'reason', 'not_authenticated'); end if;
  delete from public.matchmaking_queue where user_id = v_me and game_type = p_game_type;
  update public.match_invites set status = 'cancelled' where from_user_id = v_me and game_type = p_game_type and status = 'open';
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_has_rupee then
    execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id = $2 $sql$ using p_entry_fee, v_me;
  else
    update public.wallet set balance = balance + p_entry_fee, updated_at = now() where user_id = v_me;
  end if;
  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Stake refund — no opponent found (' || p_game_type || ')', 'credit', p_entry_fee);
  return json_build_object('ok', true, 'refunded', p_entry_fee);
end; $$;
grant execute on function public.refund_stake_on_no_opponent(text, integer) to authenticated;


-- ============================================================
-- WITHDRAWAL REQUESTS
-- ============================================================
create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  full_name text, email text, avatar_url text, referral_code text,
  total_matches integer default 0, win_rate integer default 0,
  wallet_balance_at_request integer not null default 0,
  upi_id text not null,
  amount integer not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'rejected')),
  admin_note text,
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz, paid_at timestamptz
);
create index if not exists withdrawal_requests_status_idx on public.withdrawal_requests (status, requested_at desc);
create index if not exists withdrawal_requests_user_idx on public.withdrawal_requests (user_id, requested_at desc);
alter table public.withdrawal_requests enable row level security;
drop policy if exists "Users can view their own withdrawals" on public.withdrawal_requests;
create policy "Users can view their own withdrawals" on public.withdrawal_requests for select using (auth.uid() = user_id);
drop policy if exists "Users can create their own withdrawals" on public.withdrawal_requests;
create policy "Users can create their own withdrawals" on public.withdrawal_requests for insert with check (auth.uid() = user_id);
do $$ begin begin alter publication supabase_realtime add table public.withdrawal_requests; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.withdrawal_requests replica identity full;


create or replace function public.create_withdrawal_request(p_upi_id text, p_amount integer)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid(); v_user public.users; v_wallet public.wallet;
  v_matches integer := 0; v_wins integer := 0; v_winrate integer := 0;
  v_request_id uuid; v_has_rupee boolean;
begin
  if v_me is null then return json_build_object('ok', false, 'message', 'Not authenticated.'); end if;
  if p_upi_id is null or length(trim(p_upi_id)) < 3 then return json_build_object('ok', false, 'message', 'Please enter a valid UPI ID.'); end if;
  if p_amount is null or p_amount < 150 then return json_build_object('ok', false, 'message', 'Minimum withdrawal is ₹150.'); end if;
  select * into v_user from public.users where id = v_me;
  select * into v_wallet from public.wallet where user_id = v_me;
  if v_wallet is null then return json_build_object('ok', false, 'message', 'Wallet not found.'); end if;
  if v_wallet.balance < p_amount then return json_build_object('ok', false, 'message', 'Insufficient balance.'); end if;
  select count(*) into v_matches from public.match_history where user_id = v_me;
  select count(*) into v_wins from public.match_history where user_id = v_me and result = 'VICTORY';
  if v_matches > 0 then v_winrate := round((v_wins::numeric / v_matches::numeric) * 100); end if;
  insert into public.withdrawal_requests (user_id, full_name, email, avatar_url, referral_code, total_matches, win_rate, wallet_balance_at_request, upi_id, amount, status)
  values (v_me, v_user.full_name, v_user.email, v_user.avatar_url, v_user.referral_code, v_matches, v_winrate, v_wallet.balance, trim(p_upi_id), p_amount, 'pending')
  returning id into v_request_id;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_has_rupee then
    execute $sql$ update public.wallet set balance = balance - $1, "₹" = "₹" - $1, updated_at = now() where user_id = $2 $sql$ using p_amount, v_me;
  else
    update public.wallet set balance = balance - p_amount, updated_at = now() where user_id = v_me;
  end if;
  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Withdrawal request — ₹' || p_amount || ' to ' || trim(p_upi_id), 'debit', p_amount);
  return json_build_object('ok', true, 'request_id', v_request_id, 'message', 'Withdrawal request submitted. Will be processed within 7–8 hours.');
end; $$;
grant execute on function public.create_withdrawal_request(text, integer) to authenticated;


create or replace function public.get_my_withdrawals()
returns table (id uuid, amount integer, upi_id text, status text, requested_at timestamptz, paid_at timestamptz, admin_note text)
language sql security definer set search_path = public as $$
  select id, amount, upi_id, status, requested_at, paid_at, admin_note
  from public.withdrawal_requests
  where user_id = auth.uid()
  order by requested_at desc;
$$;
grant execute on function public.get_my_withdrawals() to authenticated;


create or replace function public.mark_withdrawal_paid(p_request_id uuid, p_admin_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_req public.withdrawal_requests;
begin
  select * into v_req from public.withdrawal_requests where id = p_request_id for update;
  if v_req is null then return json_build_object('ok', false, 'message', 'Request not found.'); end if;
  if v_req.status = 'paid' then return json_build_object('ok', true, 'already_paid', true); end if;
  update public.withdrawal_requests set status = 'paid', paid_at = now(), reviewed_at = now(), admin_note = coalesce(p_admin_note, admin_note) where id = p_request_id;
  insert into public.notifications (user_id, title, body, type, icon)
  values (v_req.user_id, 'Withdrawal Paid', 'Your withdrawal of ₹' || v_req.amount || ' has been paid to ' || v_req.upi_id, 'withdrawal', 'check');
  return json_build_object('ok', true, 'message', 'Marked as paid.');
end; $$;
grant execute on function public.mark_withdrawal_paid(uuid, text) to authenticated;


create or replace function public.mark_withdrawal_rejected(p_request_id uuid, p_admin_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_req public.withdrawal_requests; v_has_rupee boolean;
begin
  select * into v_req from public.withdrawal_requests where id = p_request_id for update;
  if v_req is null then return json_build_object('ok', false, 'message', 'Request not found.'); end if;
  if v_req.status <> 'pending' and v_req.status <> 'processing' then return json_build_object('ok', false, 'message', 'Cannot reject — already ' || v_req.status); end if;
  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_has_rupee then
    execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id = $2 $sql$ using v_req.amount, v_req.user_id;
  else
    update public.wallet set balance = balance + v_req.amount, updated_at = now() where user_id = v_req.user_id;
  end if;
  insert into public.transactions (user_id, description, type, amount)
  values (v_req.user_id, 'Withdrawal rejected — refunded ₹' || v_req.amount, 'credit', v_req.amount);
  update public.withdrawal_requests set status = 'rejected', reviewed_at = now(), admin_note = coalesce(p_admin_note, admin_note) where id = p_request_id;
  insert into public.notifications (user_id, title, body, type, icon)
  values (v_req.user_id, 'Withdrawal Rejected', 'Your withdrawal of ₹' || v_req.amount || ' was rejected. Amount refunded to wallet.' || coalesce(' Reason: ' || p_admin_note, ''), 'withdrawal', 'alert');
  return json_build_object('ok', true, 'message', 'Rejected and refunded.');
end; $$;
grant execute on function public.mark_withdrawal_rejected(uuid, text) to authenticated;


-- ============================================================
-- NOTIFICATIONS (v11.0)
-- ============================================================
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users (id) on delete cascade,
  title text not null,
  body text,
  type text not null default 'general',
  icon text default 'bell',
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id, is_read) where is_read = false;

alter table public.notifications enable row level security;

drop policy if exists "Users view own notifications" on public.notifications;
create policy "Users view own notifications"
  on public.notifications for select
  using (user_id = auth.uid() or user_id is null);

drop policy if exists "Users update own notifications" on public.notifications;
create policy "Users update own notifications"
  on public.notifications for update
  using (user_id = auth.uid());

drop policy if exists "Users insert own notifications" on public.notifications;
create policy "Users insert own notifications"
  on public.notifications for insert
  with check (user_id = auth.uid() or user_id is null);

do $$ begin begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.notifications replica identity full;


-- RPC: mark_notifications_read
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ids is null then
    update public.notifications set is_read = true where user_id = auth.uid() and is_read = false;
  else
    update public.notifications set is_read = true where user_id = auth.uid() and id = any(p_ids);
  end if;
end; $$;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;


-- RPC: send_notification (broadcast or targeted)
-- Usage:
--   SELECT send_notification('Title', 'Body', NULL);                    -- to ALL users
--   SELECT send_notification('Title', 'Body', 'USER-UUID-HERE');        -- to one user
create or replace function public.send_notification(
  p_title text,
  p_body text default null,
  p_user_id uuid default null,
  p_type text default 'general',
  p_icon text default 'bell'
)
returns json language plpgsql security definer set search_path = public as $$
declare v_count integer := 0;
begin
  if p_title is null or length(trim(p_title)) = 0 then
    return json_build_object('ok', false, 'message', 'Title required.');
  end if;

  if p_user_id is not null then
    insert into public.notifications (user_id, title, body, type, icon)
    values (p_user_id, p_title, p_body, p_type, p_icon);
    v_count := 1;
  else
    insert into public.notifications (user_id, title, body, type, icon)
    select u.id, p_title, p_body, p_type, p_icon
    from public.users u;
    get diagnostics v_count = row_count;
  end if;

  return json_build_object('ok', true, 'sent', v_count);
end; $$;
grant execute on function public.send_notification(text, text, uuid, text, text) to authenticated;


-- ============================================================
-- ADMIN VIEWS
-- ============================================================
create or replace view public.admin_pending_withdrawals as
select
  wr.id as request_id,
  wr.full_name as name,
  wr.email as email,
  wr.referral_code as referral,
  wr.upi_id as upi_id,
  wr.amount as amount,
  wr.total_matches as matches,
  wr.win_rate as win_rate,
  wr.wallet_balance_at_request as wallet_at_request,
  to_char(wr.requested_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as requested_ist,
  wr.status as status,
  wr.user_id as user_id
from public.withdrawal_requests wr
where wr.status in ('pending', 'processing')
order by wr.requested_at asc;
grant select on public.admin_pending_withdrawals to authenticated;


create or replace view public.admin_withdrawal_history as
select
  wr.id as request_id,
  wr.full_name as name,
  wr.email as email,
  wr.upi_id as upi_id,
  wr.amount as amount,
  wr.status as status,
  to_char(wr.requested_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as requested_ist,
  to_char(wr.paid_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as paid_ist,
  wr.admin_note as note
from public.withdrawal_requests wr
order by wr.requested_at desc;
grant select on public.admin_withdrawal_history to authenticated;


create or replace view public.admin_users_overview as
select
  u.id as user_id,
  u.full_name as name,
  u.email as email,
  u.referral_code as referral,
  coalesce(w.balance, 0) as wallet_balance,
  coalesce((select count(*) from public.match_history mh where mh.user_id = u.id), 0) as total_matches,
  coalesce((select count(*) from public.match_history mh where mh.user_id = u.id and mh.result = 'VICTORY'), 0) as total_wins,
  coalesce((select count(*) from public.withdrawal_requests wr where wr.user_id = u.id and wr.status = 'pending'), 0) as pending_withdrawals,
  to_char(u.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as joined_ist,
  to_char(u.last_seen at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as last_seen_ist
from public.users u
left join public.wallet w on w.user_id = u.id
order by u.created_at desc;
grant select on public.admin_users_overview to authenticated;


-- ============================================================
-- END OF SCHEMA v11.0
-- ============================================================
