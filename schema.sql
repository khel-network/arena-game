-- ============================================================
-- SkillClash MASTER SCHEMA v14.0
-- Base: v12.1  +  v13.0 additions  +  v14 fixes
--
-- v14.0 fixes vs v13.0:
--   * Fixed get_user_streak() — no more limit-before-aggregate bug
--   * Removed duplicate match-end notifications from
--     end_session_with_state() (client-side now owns match receipts)
--   * Minor: safer undefined_table guards on notification inserts
-- ============================================================

-- ============================================================
-- 1. USERS
-- ============================================================
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

create unique index if not exists users_referral_code_key on public.users (referral_code) where referral_code is not null;

alter table public.users enable row level security;

drop policy if exists "Users can view their own profile" on public.users;
drop policy if exists "Authenticated users can view profiles" on public.users;
create policy "Authenticated users can view profiles" on public.users for select using (auth.role() = 'authenticated');

drop policy if exists "Users can update their own profile" on public.users;
create policy "Users can update their own profile" on public.users for update using (auth.uid() = id);

drop policy if exists "Users can insert their own profile" on public.users;
create policy "Users can insert their own profile" on public.users for insert with check (auth.uid() = id);

-- ============================================================
-- 2. WALLET
-- ============================================================
create table if not exists public.wallet (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users(id) on delete cascade,
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

do $$ begin begin alter table public.wallet add constraint wallet_balance_nonneg check (balance >= 0); exception when duplicate_object then null; end; end $$;

update public.wallet w
set
  email = coalesce(w.email, u.email),
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

-- ============================================================
-- 3. SYNC TRIGGER (users → wallet)
-- ============================================================
create or replace function public.sync_wallet_from_users() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  update public.wallet set email = new.email, full_name = new.full_name where user_id = new.id;
  return new;
end; $$;

drop trigger if exists on_user_profile_updated on public.users;
create trigger on_user_profile_updated
after update of email, full_name on public.users
for each row execute procedure public.sync_wallet_from_users();

-- ============================================================
-- 4. MATCHMAKING QUEUE
-- ============================================================
create table if not exists public.matchmaking_queue (
  user_id uuid primary key references public.users(id) on delete cascade,
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

-- ============================================================
-- 5. LEGACY MATCHES
-- ============================================================
create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users(id),
  player2_id uuid not null references public.users(id),
  status text not null default 'active',
  winner_id uuid references public.users(id),
  entry_fee integer not null default 20,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

alter table public.matches enable row level security;

drop policy if exists "Players can view their own matches" on public.matches;
create policy "Players can view their own matches" on public.matches for select
  using (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can create a match they are part of" on public.matches;
create policy "Players can create a match they are part of" on public.matches for insert
  with check (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can update their own matches" on public.matches;
create policy "Players can update their own matches" on public.matches for update
  using (auth.uid() = player1_id or auth.uid() = player2_id);

-- ============================================================
-- 6. TRANSACTIONS
-- ============================================================
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
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

-- ============================================================
-- 7. MATCH HISTORY
-- ============================================================
create table if not exists public.match_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
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

-- ============================================================
-- 8. GAME SESSIONS
-- ============================================================
create table if not exists public.game_sessions (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users(id) on delete cascade,
  player2_id uuid references public.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  current_turn text not null default 'player1',
  status text not null default 'active' check (status in ('active', 'completed', 'abandoned')),
  winner_id uuid references public.users(id),
  entry_fee integer not null default 20,
  reward integer not null default 30,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.game_sessions add column if not exists stake_locked boolean not null default false;
alter table public.game_sessions add column if not exists abandoned_at timestamptz;
alter table public.game_sessions add column if not exists settled_at timestamptz;
alter table public.game_sessions add column if not exists settled_by uuid references public.users(id);

create index if not exists game_sessions_players_idx on public.game_sessions (player1_id, player2_id);
create index if not exists game_sessions_status_idx on public.game_sessions (status);
create index if not exists game_sessions_game_type_status_idx on public.game_sessions (game_type, status);

alter table public.game_sessions enable row level security;

drop policy if exists "Players can view their game sessions" on public.game_sessions;
create policy "Players can view their game sessions" on public.game_sessions for select
  using (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can insert their game sessions" on public.game_sessions;
create policy "Players can insert their game sessions" on public.game_sessions for insert
  with check (auth.uid() = player1_id or auth.uid() = player2_id);

drop policy if exists "Players can update their game sessions" on public.game_sessions;
create policy "Players can update their game sessions" on public.game_sessions for update
  using (auth.uid() = player1_id or auth.uid() = player2_id);

do $$ begin begin alter publication supabase_realtime add table public.game_sessions; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.game_sessions replica identity full;

-- ============================================================
-- 9. GAME EVENTS
-- ============================================================
create table if not exists public.game_events (
  id bigserial primary key,
  session_id uuid references public.game_sessions(id) on delete cascade,
  user_id uuid references public.users(id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists game_events_session_idx on public.game_events (session_id, created_at desc);

alter table public.game_events enable row level security;

drop policy if exists "Players can view events for their sessions" on public.game_events;
create policy "Players can view events for their sessions" on public.game_events for select
  using (exists (
    select 1 from public.game_sessions gs
    where gs.id = game_events.session_id
      and (gs.player1_id = auth.uid() or gs.player2_id = auth.uid())
  ));

drop policy if exists "Authenticated can insert events" on public.game_events;
create policy "Authenticated can insert events" on public.game_events for insert
  with check (auth.role() = 'authenticated');

-- ============================================================
-- 10. NOTIFICATIONS
-- ============================================================
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete cascade,
  title text not null,
  body text,
  type text not null default 'general',
  icon text default 'bell',
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.notifications add column if not exists icon text default 'bell';

create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_unread_idx on public.notifications (user_id, is_read) where is_read = false;

alter table public.notifications enable row level security;

drop policy if exists "Users view own notifications" on public.notifications;
create policy "Users view own notifications" on public.notifications for select
  using (user_id = auth.uid() or user_id is null);

drop policy if exists "Users update own notifications" on public.notifications;
create policy "Users update own notifications" on public.notifications for update using (user_id = auth.uid());

drop policy if exists "Users insert own notifications" on public.notifications;
create policy "Users insert own notifications" on public.notifications for insert
  with check (user_id = auth.uid() or user_id is null);

do $$ begin begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.notifications replica identity full;

-- ============================================================
-- 11. AUTO-PROVISION NEW USERS
-- ============================================================
create or replace function public.handle_new_user() returns trigger language plpgsql security definer
set search_path = public as $$
declare v_has_rupee boolean;
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'avatar_url')
  on conflict (id) do nothing;

  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;

  if v_has_rupee then
    execute $sql$ insert into public.wallet (user_id, balance, "₹", email, full_name, first_login_at)
      values ($1, 25, 25, $2, $3, now()) on conflict (user_id) do nothing $sql$
    using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  else
    execute $sql$ insert into public.wallet (user_id, balance, email, full_name, first_login_at)
      values ($1, 25, $2, $3, now()) on conflict (user_id) do nothing $sql$
    using new.id, new.email, new.raw_user_meta_data ->> 'full_name';
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (new.id, 'Welcome bonus', 'credit', 25);

  begin
    insert into public.notifications (user_id, title, body, type, icon)
    values (new.id, 'Welcome to SkillClash!', 'You received ₹25 welcome bonus. Play your first match now!', 'gift', 'gift');
  exception when undefined_table then null;
  end;

  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users for each row
execute procedure public.handle_new_user();

-- ============================================================
-- 12. CLAIM_OPPONENT (per-candidate loop + blocked reason)
-- ============================================================
drop function if exists public.claim_opponent(text, integer, integer, text, text);

create or replace function public.claim_opponent(
  p_game_type text,
  p_entry_fee integer default 20,
  p_reward integer default 30,
  p_fingerprint text default null,
  p_ip text default null
) returns json language plpgsql security definer
set search_path = public as $$
declare
  v_opponent_id uuid;
  v_me uuid := auth.uid();
  v_session_id uuid;
  v_my_email text;
  v_my_username text;
  v_opp_email text;
  v_opp_username text;
  v_opp_fp text;
  v_opp_ip text;
  v_recent_pair_count integer;
  v_blocked_reason text := null;
  v_candidate record;
begin
  if v_me is null then
    return json_build_object('matched', false, 'reason', 'not_authenticated');
  end if;

  select email, full_name into v_my_email, v_my_username from public.users where id = v_me;
  v_my_email := lower(coalesce(v_my_email, ''));
  v_my_username := lower(regexp_replace(coalesce(v_my_username, ''), '[^a-zA-Z0-9]', '', 'g'));

  -- purge stale queue entries
  delete from public.matchmaking_queue mq
  using public.users u
  where mq.user_id = u.id
    and mq.game_type = p_game_type
    and u.last_seen < now() - interval '25 seconds';

  -- iterate candidates, block if needed, else match
  for v_candidate in
    select mq.user_id, mq.device_fp, mq.last_ip
    from public.matchmaking_queue mq
    join public.users u on u.id = mq.user_id
    where mq.game_type = p_game_type
      and mq.user_id <> v_me
      and u.last_seen >= now() - interval '25 seconds'
    order by mq.created_at asc
    for update of mq skip locked
  loop
    v_opponent_id := v_candidate.user_id;
    select lower(coalesce(email, '')),
           lower(regexp_replace(coalesce(full_name, ''), '[^a-zA-Z0-9]', '', 'g'))
      into v_opp_email, v_opp_username
      from public.users where id = v_opponent_id;
    v_opp_fp := coalesce(v_candidate.device_fp, '');
    v_opp_ip := coalesce(v_candidate.last_ip, '');

    v_blocked_reason := null;
    if v_opp_email <> '' and v_opp_email = v_my_email then
      v_blocked_reason := 'Same email address detected';
    elsif v_my_username <> '' and length(v_my_username) >= 5
          and length(v_opp_username) >= 5
          and substring(v_my_username from 1 for 5) = substring(v_opp_username from 1 for 5) then
      v_blocked_reason := 'Similar username pattern detected';
    elsif p_fingerprint is not null and v_opp_fp <> '' and v_opp_fp = p_fingerprint then
      v_blocked_reason := 'Same device fingerprint detected';
    elsif p_ip is not null and v_opp_ip <> '' and v_opp_ip = p_ip then
      v_blocked_reason := 'Same IP address detected';
    else
      select count(*) into v_recent_pair_count
      from public.game_sessions gs
      where gs.game_type = p_game_type
        and gs.created_at > now() - interval '24 hours'
        and ((gs.player1_id = v_opponent_id and gs.player2_id = v_me)
          or (gs.player1_id = v_me and gs.player2_id = v_opponent_id));
      if v_recent_pair_count >= 2 then
        v_blocked_reason := 'You recently played this opponent twice. Try again later.';
      end if;
    end if;

    if v_blocked_reason is null then
      delete from public.matchmaking_queue where user_id in (v_opponent_id, v_me);
      insert into public.game_sessions (
        game_type, player1_id, player2_id, state, current_turn, status, entry_fee, reward, stake_locked
      ) values (
        p_game_type, v_opponent_id, v_me, '{}'::jsonb, 'player1', 'active', p_entry_fee, p_reward, true
      ) returning id into v_session_id;

      insert into public.game_events (session_id, user_id, event_type, payload)
      values (v_session_id, v_me, 'match_created',
        jsonb_build_object('opponent', v_opponent_id, 'game', p_game_type));

      return json_build_object(
        'matched', true, 'blocked', false,
        'session_id', v_session_id,
        'opponent_id', v_opponent_id,
        'you_are', 'player2'
      );
    end if;
  end loop;

  -- everyone was blocked → report reason
  if v_opponent_id is not null and v_blocked_reason is not null then
    begin
      insert into public.notifications (user_id, title, body, type, icon)
      values (v_opponent_id, '⚠️ Match blocked for FairPlay',
        'A candidate was flagged: ' || v_blocked_reason || '. You were not charged.',
        'alert', 'alert');
    exception when undefined_table then null;
    end;

    return json_build_object(
      'matched', true, 'blocked', true,
      'reason', v_blocked_reason
    );
  end if;

  return json_build_object('matched', false);
end; $$;

grant execute on function public.claim_opponent(text, integer, integer, text, text) to authenticated;

-- ============================================================
-- 13. REDEEM_REFERRAL_CODE
-- ============================================================
create or replace function public.redeem_referral_code(p_code text) returns json language plpgsql security definer
set search_path = public as $$
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

  begin
    insert into public.notifications (user_id, title, body, type, icon)
    values (v_me, 'Referral bonus applied', 'You received ₹' || v_bonus || ' for using a referral code.', 'reward', 'gift');
    insert into public.notifications (user_id, title, body, type, icon)
    values (v_referrer_id, 'Referral reward', 'A friend joined using your code. You received ₹' || v_bonus || '.', 'reward', 'gift');
  exception when undefined_table then null;
  end;

  return json_build_object('success', true, 'message', 'Referral applied! You received ₹' || v_bonus || '.');
end; $$;

grant execute on function public.redeem_referral_code(text) to authenticated;

-- ============================================================
-- 14. PAYMENT REQUESTS + APPROVAL TRIGGER
-- ============================================================
create table if not exists public.payment_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
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

create or replace function public.process_payment_approval() returns trigger language plpgsql security definer
set search_path = public as $$
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

    begin
      insert into public.notifications (user_id, title, body, type, icon)
      values (new.user_id, '💰 Wallet topped up', '₹' || new.tokens_to_credit || ' added to your wallet. Play now and win more!', 'reward', 'gift');
    exception when undefined_table then null;
    end;

    new.reviewed_at = now();
  end if;
  return new;
end; $$;

drop trigger if exists on_payment_approved on public.payment_requests;
create trigger on_payment_approved before update on public.payment_requests
  for each row execute procedure public.process_payment_approval();

-- ============================================================
-- 15. MATCH INVITES
-- ============================================================
create table if not exists public.match_invites (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null references public.users(id) on delete cascade,
  game_type text not null,
  game_name text not null,
  entry_fee integer not null default 20,
  reward integer not null default 30,
  status text not null default 'open' check (status in ('open', 'accepted', 'expired', 'cancelled')),
  accepted_by uuid references public.users(id),
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
create policy "Users can update invites they created or accepted" on public.match_invites for update
  using (auth.uid() = from_user_id or auth.uid() = accepted_by);

do $$ begin begin alter publication supabase_realtime add table public.match_invites; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.match_invites replica identity full;

create or replace function public.expire_old_invites() returns void language plpgsql security definer
set search_path = public as $$
begin
  update public.match_invites set status = 'expired' where status = 'open' and expires_at < now();
end; $$;

grant execute on function public.expire_old_invites() to authenticated;

create or replace function public.accept_match_invite(p_invite_id uuid) returns json language plpgsql security definer
set search_path = public as $$
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

-- ============================================================
-- 16. SETTLEMENT RPCs
-- ============================================================
-- v14 NOTE: notifications for win/loss were REMOVED here.
-- Client-side sendMatchNotification() now owns them, so we
-- don't double-notify. Wallet, transactions and match_history
-- are still written server-side exactly as before.
create or replace function public.end_session_with_state(
  p_session_id uuid,
  p_final_state jsonb default '{}'::jsonb,
  p_winner_id uuid default null
) returns json language plpgsql security definer
set search_path = public as $$
declare
  v_session public.game_sessions; v_me uuid := auth.uid(); v_is_player boolean;
  v_entry integer; v_reward integer; v_has_rupee boolean;
  v_loser uuid;
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

    v_loser := case when v_session.player1_id = p_winner_id then v_session.player2_id else v_session.player1_id end;

    insert into public.match_history (user_id, game, opponent, result, reward)
    select p_winner_id, v_session.game_type, coalesce(u.full_name, 'Opponent'), 'VICTORY', v_reward
    from public.users u where u.id = v_loser;

    insert into public.match_history (user_id, game, opponent, result, reward)
    select v_loser, v_session.game_type, coalesce(u.full_name, 'Opponent'), 'DEFEAT', -v_entry
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

create or replace function public.abandon_session(p_session_id uuid) returns json language plpgsql security definer
set search_path = public as $$
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

create or replace function public.refund_stake_on_no_opponent(p_game_type text, p_entry_fee integer) returns json language plpgsql security definer
set search_path = public as $$
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
-- 17. WITHDRAWAL REQUESTS
-- ============================================================
create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  full_name text,
  email text,
  avatar_url text,
  referral_code text,
  total_matches integer default 0,
  win_rate integer default 0,
  wallet_balance_at_request integer not null default 0,
  upi_id text not null,
  amount integer not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'rejected')),
  admin_note text,
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  paid_at timestamptz
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

create or replace function public.create_withdrawal_request(p_upi_id text, p_amount integer) returns json language plpgsql security definer
set search_path = public as $$
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

create or replace function public.get_my_withdrawals() returns table (
  id uuid, amount integer, upi_id text, status text,
  requested_at timestamptz, paid_at timestamptz, admin_note text
) language sql security definer set search_path = public as $$
  select id, amount, upi_id, status, requested_at, paid_at, admin_note
  from public.withdrawal_requests
  where user_id = auth.uid()
  order by requested_at desc;
$$;

grant execute on function public.get_my_withdrawals() to authenticated;

create or replace function public.mark_withdrawal_paid(p_request_id uuid, p_admin_note text default null) returns json language plpgsql security definer
set search_path = public as $$
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

create or replace function public.mark_withdrawal_rejected(p_request_id uuid, p_admin_note text default null) returns json language plpgsql security definer
set search_path = public as $$
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
-- 18. NOTIFICATIONS RPCs
-- ============================================================
create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns void language plpgsql security definer
set search_path = public as $$
begin
  if p_ids is null then
    update public.notifications set is_read = true where user_id = auth.uid() and is_read = false;
  else
    update public.notifications set is_read = true where user_id = auth.uid() and id = any(p_ids);
  end if;
end; $$;

grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

create or replace function public.send_notification(
  p_title text, p_body text default null, p_user_id uuid default null,
  p_type text default 'general', p_icon text default 'bell'
) returns json language plpgsql security definer
set search_path = public as $$
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
    select u.id, p_title, p_body, p_type, p_icon from public.users u;
    get diagnostics v_count = row_count;
  end if;

  return json_build_object('ok', true, 'sent', v_count);
end; $$;

grant execute on function public.send_notification(text, text, uuid, text, text) to authenticated;

create or replace function public.admin_send_broadcast(
  p_title text, p_body text default null,
  p_type text default 'promo', p_icon text default 'bell'
) returns json language plpgsql security definer
set search_path = public as $$
begin
  return public.send_notification(p_title, p_body, null, p_type, p_icon);
end; $$;

grant execute on function public.admin_send_broadcast(text, text, text, text) to authenticated;

-- ============================================================
-- 19. ADMIN VIEWS
-- ============================================================
create or replace view public.admin_pending_withdrawals as
select
  wr.id as request_id, wr.full_name as name, wr.email as email,
  wr.referral_code as referral, wr.upi_id as upi_id, wr.amount as amount,
  wr.total_matches as matches, wr.win_rate as win_rate,
  wr.wallet_balance_at_request as wallet_at_request,
  to_char(wr.requested_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as requested_ist,
  wr.status as status, wr.user_id as user_id
from public.withdrawal_requests wr
where wr.status in ('pending', 'processing')
order by wr.requested_at asc;

grant select on public.admin_pending_withdrawals to authenticated;

create or replace view public.admin_withdrawal_history as
select
  wr.id as request_id, wr.full_name as name, wr.email as email,
  wr.upi_id as upi_id, wr.amount as amount, wr.status as status,
  to_char(wr.requested_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as requested_ist,
  to_char(wr.paid_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') as paid_ist,
  wr.admin_note as note
from public.withdrawal_requests wr
order by wr.requested_at desc;

grant select on public.admin_withdrawal_history to authenticated;

create or replace view public.admin_users_overview as
select
  u.id as user_id, u.full_name as name, u.email as email, u.referral_code as referral,
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
-- 20. MATCH-STARTED NOTIFICATION TRIGGER
-- ============================================================
create or replace function public.notify_match_started() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  begin
    if new.player1_id is not null then
      insert into public.notifications (user_id, title, body, type, icon)
      values (new.player1_id, 'Match starting', 'Your ' || new.game_type || ' match has been created.', 'info', 'fire');
    end if;
    if new.player2_id is not null then
      insert into public.notifications (user_id, title, body, type, icon)
      values (new.player2_id, 'Match starting', 'Your ' || new.game_type || ' match has been created.', 'info', 'fire');
    end if;
  exception when undefined_table then null;
  end;
  return new;
end; $$;

drop trigger if exists on_game_session_created_notify on public.game_sessions;
create trigger on_game_session_created_notify
after insert on public.game_sessions for each row
execute procedure public.notify_match_started();

-- ============================================================
-- 21. DAILY LOGIN BONUS
-- ============================================================
create table if not exists public.daily_bonus_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  claim_date date not null default (now() at time zone 'Asia/Kolkata')::date,
  amount integer not null,
  streak_day integer not null default 1,
  created_at timestamptz not null default now(),
  unique (user_id, claim_date)
);

create index if not exists daily_bonus_user_date_idx on public.daily_bonus_claims (user_id, claim_date desc);

alter table public.daily_bonus_claims enable row level security;

drop policy if exists "Users view own daily bonus" on public.daily_bonus_claims;
create policy "Users view own daily bonus" on public.daily_bonus_claims for select using (auth.uid() = user_id);

create or replace function public.claim_daily_bonus() returns json language plpgsql security definer
set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_yesterday date := v_today - interval '1 day';
  v_last_claim record;
  v_streak integer := 1;
  v_amount integer;
  v_has_rupee boolean;
  v_new_balance integer;
begin
  if v_me is null then return json_build_object('ok', false, 'message', 'Not authenticated'); end if;

  if exists (select 1 from public.daily_bonus_claims where user_id = v_me and claim_date = v_today) then
    return json_build_object('ok', false, 'already_claimed', true, 'message', 'Already claimed today');
  end if;

  select * into v_last_claim from public.daily_bonus_claims
    where user_id = v_me and claim_date = v_yesterday limit 1;
  if v_last_claim is not null then
    v_streak := least(v_last_claim.streak_day + 1, 7);
  end if;

  v_amount := case v_streak
    when 1 then 5 when 2 then 6 when 3 then 7 when 4 then 8
    when 5 then 10 when 6 then 12 when 7 then 25
    else 5
  end;

  insert into public.daily_bonus_claims (user_id, claim_date, amount, streak_day)
  values (v_me, v_today, v_amount, v_streak);

  select exists (select 1 from information_schema.columns where table_schema='public' and table_name='wallet' and column_name='₹') into v_has_rupee;
  if v_has_rupee then
    execute $sql$ update public.wallet set balance = balance + $1, "₹" = "₹" + $1, updated_at = now() where user_id = $2 returning balance into $3 $sql$
    using v_amount, v_me, v_new_balance;
  else
    update public.wallet set balance = balance + v_amount, updated_at = now() where user_id = v_me returning balance into v_new_balance;
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (v_me, 'Daily login bonus — Day ' || v_streak, 'credit', v_amount);

  begin
    insert into public.notifications (user_id, title, body, type, icon)
    values (v_me, '🎁 Day ' || v_streak || ' bonus: ₹' || v_amount,
      'Come back tomorrow to keep your streak going!', 'gift', 'gift');
  exception when undefined_table then null;
  end;

  return json_build_object('ok', true, 'amount', v_amount, 'streak_day', v_streak, 'new_balance', v_new_balance);
end; $$;

grant execute on function public.claim_daily_bonus() to authenticated;

create or replace function public.get_daily_bonus_status() returns json language plpgsql security definer
set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_yesterday date := v_today - interval '1 day';
  v_last_claim record;
  v_streak integer := 0;
  v_next_streak integer := 1;
  v_next_amount integer;
  v_claimed boolean := false;
begin
  if v_me is null then return json_build_object('ok', false); end if;

  if exists (select 1 from public.daily_bonus_claims where user_id = v_me and claim_date = v_today) then
    v_claimed := true;
  end if;

  select * into v_last_claim from public.daily_bonus_claims
    where user_id = v_me and claim_date in (v_today, v_yesterday)
    order by claim_date desc limit 1;

  if v_last_claim is not null then
    if v_last_claim.claim_date = v_yesterday then
      v_streak := least(v_last_claim.streak_day, 6);
      v_next_streak := least(v_last_claim.streak_day + 1, 7);
    else
      v_streak := v_last_claim.streak_day;
      v_next_streak := v_last_claim.streak_day;
    end if;
  end if;

  v_next_amount := case v_next_streak
    when 1 then 5 when 2 then 6 when 3 then 7 when 4 then 8
    when 5 then 10 when 6 then 12 when 7 then 25
    else 5
  end;

  return json_build_object(
    'ok', true, 'claimed_today', v_claimed,
    'current_streak', v_streak, 'next_streak', v_next_streak,
    'next_amount', v_next_amount
  );
end; $$;

grant execute on function public.get_daily_bonus_status() to authenticated;

-- ============================================================
-- 22. WIN STREAK (FIXED — v14)
-- ============================================================
-- v14 fix: the old version put "limit 20" inside the CTE, which
-- was applied before the outer aggregate. This version scans the
-- full recent ordered history, finds the first non-victory, and
-- counts victories above it. Correct for any streak length.
create or replace function public.get_user_streak(p_user_id uuid default null)
returns json language plpgsql security definer
set search_path = public as $$
declare
  v_uid uuid := coalesce(p_user_id, auth.uid());
  v_streak integer := 0;
  v_row record;
begin
  if v_uid is null then return json_build_object('ok', false, 'message', 'not_authenticated'); end if;
  if p_user_id is not null and p_user_id <> auth.uid() then
    -- allow public lookups of streak
    null;
  end if;

  for v_row in
    select result from public.match_history
    where user_id = v_uid
    order by created_at desc
    limit 100
  loop
    if v_row.result = 'VICTORY' then
      v_streak := v_streak + 1;
    else
      exit;
    end if;
  end loop;

  return json_build_object('ok', true, 'current_streak', v_streak);
end; $$;

grant execute on function public.get_user_streak(uuid) to authenticated;

-- ============================================================
-- 23. SUPPORT TICKETS (realtime)
-- ============================================================
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  subject text not null,
  category text not null default 'other',
  status text not null default 'open' check (status in ('open', 'answered', 'resolved', 'closed')),
  priority text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);

create index if not exists support_tickets_user_idx on public.support_tickets (user_id, last_message_at desc);
create index if not exists support_tickets_status_idx on public.support_tickets (status, last_message_at desc);

create table if not exists public.ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_id uuid references public.users(id) on delete set null,
  sender_role text not null check (sender_role in ('user', 'admin')),
  body text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists ticket_messages_ticket_idx on public.ticket_messages (ticket_id, created_at asc);

alter table public.support_tickets enable row level security;
alter table public.ticket_messages enable row level security;

drop policy if exists "Users see own tickets" on public.support_tickets;
create policy "Users see own tickets" on public.support_tickets for select
  using (auth.uid() = user_id or public.is_admin());

drop policy if exists "Users create own tickets" on public.support_tickets;
create policy "Users create own tickets" on public.support_tickets for insert
  with check (auth.uid() = user_id);

drop policy if exists "Users update own tickets" on public.support_tickets;
create policy "Users update own tickets" on public.support_tickets for update
  using (auth.uid() = user_id or public.is_admin());

drop policy if exists "Users see ticket messages" on public.ticket_messages;
create policy "Users see ticket messages" on public.ticket_messages for select
  using (exists (select 1 from public.support_tickets t where t.id = ticket_id and (t.user_id = auth.uid() or public.is_admin())));

drop policy if exists "Users send ticket messages" on public.ticket_messages;
create policy "Users send ticket messages" on public.ticket_messages for insert
  with check (
    (sender_role = 'user' and sender_id = auth.uid() and exists (select 1 from public.support_tickets t where t.id = ticket_id and t.user_id = auth.uid()))
    or (sender_role = 'admin' and public.is_admin())
  );

do $$ begin begin alter publication supabase_realtime add table public.support_tickets; exception when duplicate_object then null; when undefined_object then null; end; end $$;
do $$ begin begin alter publication supabase_realtime add table public.ticket_messages; exception when duplicate_object then null; when undefined_object then null; end; end $$;
alter table public.support_tickets replica identity full;
alter table public.ticket_messages replica identity full;

create or replace function public.create_support_ticket(p_subject text, p_category text, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_ticket_id uuid;
begin
  if v_me is null then return json_build_object('ok', false, 'message', 'Not authenticated'); end if;
  if p_subject is null or length(trim(p_subject)) = 0 then return json_build_object('ok', false, 'message', 'Subject required'); end if;
  if p_body is null or length(trim(p_body)) = 0 then return json_build_object('ok', false, 'message', 'Message required'); end if;

  insert into public.support_tickets (user_id, subject, category)
  values (v_me, trim(p_subject), coalesce(p_category, 'other'))
  returning id into v_ticket_id;

  insert into public.ticket_messages (ticket_id, sender_id, sender_role, body)
  values (v_ticket_id, v_me, 'user', trim(p_body));

  return json_build_object('ok', true, 'ticket_id', v_ticket_id);
end; $$;

grant execute on function public.create_support_ticket(text, text, text) to authenticated;

create or replace function public.user_reply_ticket(p_ticket_id uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
begin
  if v_me is null then return json_build_object('ok', false, 'message', 'Not authenticated'); end if;
  if p_body is null or length(trim(p_body)) = 0 then return json_build_object('ok', false, 'message', 'Message required'); end if;

  select user_id into v_owner from public.support_tickets where id = p_ticket_id;
  if v_owner is null or v_owner <> v_me then return json_build_object('ok', false, 'message', 'Ticket not found'); end if;

  insert into public.ticket_messages (ticket_id, sender_id, sender_role, body)
  values (p_ticket_id, v_me, 'user', trim(p_body));

  update public.support_tickets
    set status = 'open', last_message_at = now(), updated_at = now()
    where id = p_ticket_id;

  return json_build_object('ok', true);
end; $$;

grant execute on function public.user_reply_ticket(uuid, text) to authenticated;

create or replace function public.admin_reply_ticket(p_ticket_id uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_user_id uuid;
begin
  if not public.is_admin() then return json_build_object('ok', false, 'message', 'Forbidden'); end if;
  if p_body is null or length(trim(p_body)) = 0 then return json_build_object('ok', false, 'message', 'Message required'); end if;

  select user_id into v_user_id from public.support_tickets where id = p_ticket_id;
  if v_user_id is null then return json_build_object('ok', false, 'message', 'Ticket not found'); end if;

  insert into public.ticket_messages (ticket_id, sender_id, sender_role, body)
  values (p_ticket_id, v_me, 'admin', trim(p_body));

  update public.support_tickets
    set status = case when status = 'open' then 'answered' else status end,
        last_message_at = now(), updated_at = now()
    where id = p_ticket_id;

  begin
    insert into public.notifications (user_id, title, body, type, icon)
    values (v_user_id, 'Support replied to your ticket', left(p_body, 80), 'info', 'bell');
  exception when undefined_table then null;
  end;

  return json_build_object('ok', true);
end; $$;

grant execute on function public.admin_reply_ticket(uuid, text) to authenticated;

create or replace function public.mark_ticket_read(p_ticket_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then
    update public.ticket_messages set is_read = true where ticket_id = p_ticket_id and sender_role = 'user';
  else
    update public.ticket_messages set is_read = true
      where ticket_id = p_ticket_id and sender_role = 'admin'
        and exists (select 1 from public.support_tickets where id = p_ticket_id and user_id = auth.uid());
  end if;
end; $$;

grant execute on function public.mark_ticket_read(uuid) to authenticated;

-- ============================================================
-- 24. ACHIEVEMENTS
-- ============================================================
create table if not exists public.achievements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  code text not null,
  unlocked_at timestamptz not null default now(),
  unique (user_id, code)
);

create index if not exists achievements_user_idx on public.achievements (user_id);

alter table public.achievements enable row level security;

drop policy if exists "Anyone view achievements" on public.achievements;
create policy "Anyone view achievements" on public.achievements for select using (true);

drop policy if exists "Users unlock own achievements" on public.achievements;
create policy "Users unlock own achievements" on public.achievements for insert with check (auth.uid() = user_id);

create or replace function public.unlock_achievement(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_new boolean := false;
begin
  if v_me is null then return json_build_object('ok', false); end if;
  begin
    insert into public.achievements (user_id, code) values (v_me, p_code);
    v_new := true;
  exception when unique_violation then v_new := false;
  end;
  return json_build_object('ok', true, 'new', v_new);
end; $$;

grant execute on function public.unlock_achievement(text) to authenticated;

-- ============================================================
-- 25. PUSH SUBSCRIPTIONS (stub for future real push)
-- ============================================================
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  endpoint text not null,
  p256dh text,
  auth text,
  user_agent text,
  created_at timestamptz not null default now(),
  unique (user_id, endpoint)
);

alter table public.push_subscriptions enable row level security;

drop policy if exists "Users manage own push" on public.push_subscriptions;
create policy "Users manage own push" on public.push_subscriptions for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- 26. REFERRAL LEADERBOARD + PROGRESS
-- ============================================================
create or replace function public.get_referral_leaderboard(p_limit integer default 10)
returns table (
  rank integer, user_id uuid, full_name text, avatar_url text, referral_count integer
) language sql security definer set search_path = public as $$
  with counts as (
    select referred_by as user_id, count(*)::integer as c
    from public.users
    where referred_by is not null
    group by referred_by
  )
  select row_number() over (order by c desc)::integer as rank,
         c.user_id, u.full_name, u.avatar_url, c.c
  from counts c
  left join public.users u on u.id = c.user_id
  order by c desc
  limit least(p_limit, 50);
$$;

grant execute on function public.get_referral_leaderboard(integer) to authenticated, anon;

create or replace function public.get_my_referral_progress()
returns json language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_count integer := 0;
begin
  if v_me is null then return json_build_object('ok', false); end if;
  select count(*) into v_count from public.users where referred_by = v_me;
  return json_build_object('ok', true, 'referral_count', v_count, 'earned', v_count * 25);
end; $$;

grant execute on function public.get_my_referral_progress() to authenticated;

-- ============================================================
-- 27. PUBLIC PROFILE
-- ============================================================
create or replace function public.get_public_profile(p_user_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_user record;
  v_wallet integer;
  v_matches integer;
  v_wins integer;
  v_streak integer;
  v_achievements json;
begin
  select id, full_name, avatar_url, referral_code, created_at, last_seen
    into v_user from public.users where id = p_user_id;
  if v_user is null then return json_build_object('ok', false, 'message', 'User not found'); end if;

  select coalesce(balance, 0) into v_wallet from public.wallet where user_id = p_user_id;
  select count(*) into v_matches from public.match_history where user_id = p_user_id;
  select count(*) into v_wins from public.match_history where user_id = p_user_id and result = 'VICTORY';

  with mm as (
    select result, row_number() over (order by created_at desc) as rn
    from public.match_history where user_id = p_user_id order by created_at desc
  )
  select coalesce((
    select count(*) from (
      select result from mm
      where rn <= (select coalesce(min(rn) - 1, (select count(*) from mm)) from mm where result <> 'VICTORY')
    ) t where result = 'VICTORY'
  ), 0) into v_streak;

  select coalesce(json_agg(code order by unlocked_at desc), '[]'::json) into v_achievements
    from public.achievements where user_id = p_user_id;

  return json_build_object(
    'ok', true,
    'user_id', v_user.id,
    'full_name', v_user.full_name,
    'avatar_url', v_user.avatar_url,
    'referral_code', v_user.referral_code,
    'joined_at', v_user.created_at,
    'last_seen', v_user.last_seen,
    'wallet_balance', coalesce(v_wallet, 0),
    'total_matches', v_matches,
    'total_wins', v_wins,
    'win_rate', case when v_matches > 0 then round((v_wins::numeric / v_matches::numeric) * 100) else 0 end,
    'current_streak', v_streak,
    'achievements', v_achievements
  );
end; $$;

grant execute on function public.get_public_profile(uuid) to authenticated, anon;

-- ============================================================
-- END OF SCHEMA v14.0
-- ============================================================
