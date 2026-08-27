-- ============================================================
-- Arena Master Schema (Hardened Security & Payment Verification)
-- ============================================================

-- 1. USERS
create table if not exists public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  referral_code text,
  referred_by uuid references public.users (id)
);

create unique index if not exists users_referral_code_key
  on public.users (referral_code) where referral_code is not null;

alter table public.users enable row level security;
drop policy if exists "Authenticated users can view profiles" on public.users;
create policy "Authenticated users can view profiles" on public.users for select using (auth.role() = 'authenticated');
drop policy if exists "Users can update their own profile" on public.users;
create policy "Users can update their own profile" on public.users for update using (auth.uid() = id);
drop policy if exists "Users can insert their own profile" on public.users;
create policy "Users can insert their own profile" on public.users for insert with check (auth.uid() = id);

-- 2. WALLET (READ-ONLY FOR CLIENTS)
create table if not exists public.wallet (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users (id) on delete cascade,
  dummy_token integer not null default 1000 check (dummy_token >= 0),
  updated_at timestamptz not null default now()
);
alter table public.wallet enable row level security;

drop policy if exists "Users can view their own wallet" on public.wallet;
create policy "Users can view their own wallet" on public.wallet for select using (auth.uid() = user_id);

-- IMPORTANT: Drop client update policy so users cannot manipulate token balance from browser console
drop policy if exists "Users can update their own wallet" on public.wallet;

-- 3. MATCHMAKING QUEUE & MATCHES
create table if not exists public.matchmaking_queue (
  user_id uuid primary key references public.users (id) on delete cascade,
  game_type text not null,
  created_at timestamptz not null default now()
);
alter table public.matchmaking_queue enable row level security;
drop policy if exists "Users can see the queue" on public.matchmaking_queue;
create policy "Users can see the queue" on public.matchmaking_queue for select using (true);
drop policy if exists "Users can join the queue as themselves" on public.matchmaking_queue;
create policy "Users can join the queue as themselves" on public.matchmaking_queue for insert with check (auth.uid() = user_id);
drop policy if exists "Users can leave the queue" on public.matchmaking_queue;
create policy "Users can leave the queue" on public.matchmaking_queue for delete using (auth.uid() = user_id);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  game_type text not null,
  player1_id uuid not null references public.users (id),
  player2_id uuid not null references public.users (id),
  status text not null default 'active',
  winner_id uuid references public.users (id),
  entry_fee integer not null default 50,
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

-- 4. TRANSACTIONS & MATCH HISTORY
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

-- 5. PAYMENT REQUESTS (Strict RLS: Insert only with status='pending')
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
create policy "Users can submit payment" on public.payment_requests for insert with check (auth.uid() = user_id and status = 'pending');

-- 6. AUTOMATED WALLET APPROVAL TRIGGER
create or replace function public.process_payment_approval()
returns trigger language plpgsql security definer set search_path = public as $$
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
create trigger on_payment_approved before update on public.payment_requests for each row execute procedure public.process_payment_approval();

-- 7. BOT & GAME PLAY TRIGGERS / FUNCTIONS
create or replace function public.process_game_stake(p_fee integer, p_desc text)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_bal integer;
begin
  select dummy_token into v_bal from public.wallet where user_id = auth.uid() for update;
  if v_bal is null or v_bal < p_fee then
    raise exception 'Insufficient balance';
  end if;
  update public.wallet set dummy_token = dummy_token - p_fee, updated_at = now() where user_id = auth.uid();
  insert into public.transactions (user_id, description, type, amount) values (auth.uid(), p_desc, 'debit', p_fee);
  return v_bal - p_fee;
end;
$$;
grant execute on function public.process_game_stake(integer, text) to authenticated;

create or replace function public.process_game_win(p_reward integer, p_game text, p_opponent text)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_bal integer;
begin
  update public.wallet set dummy_token = dummy_token + p_reward, updated_at = now() where user_id = auth.uid() returning dummy_token into v_bal;
  insert into public.transactions (user_id, description, type, amount) values (auth.uid(), 'Duel Victory: ' || p_game, 'credit', p_reward);
  insert into public.match_history (user_id, game, opponent, result, reward) values (auth.uid(), p_game, p_opponent, 'VICTORY', p_reward);
  return v_bal;
end;
$$;
grant execute on function public.process_game_win(integer, text, text) to authenticated;

create or replace function public.process_game_loss(p_game text, p_opponent text, p_fee integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.match_history (user_id, game, opponent, result, reward) values (auth.uid(), p_game, p_opponent, 'DEFEAT', -p_fee);
end;
$$;
grant execute on function public.process_game_loss(text, text, integer) to authenticated;

-- 8. REFERRAL & CLAIM OPPONENT FUNCTIONS
create or replace function public.claim_opponent(p_game_type text, p_entry_fee integer default 50)
returns public.matches language plpgsql security definer set search_path = public as $$
declare
  v_opponent_id uuid;
  v_match public.matches;
begin
  delete from public.matchmaking_queue mq using public.users u
  where mq.user_id = u.id and mq.game_type = p_game_type and u.last_seen < now() - interval '15 seconds';

  select mq.user_id into v_opponent_id from public.matchmaking_queue mq join public.users u on u.id = mq.user_id
  where mq.game_type = p_game_type and mq.user_id <> auth.uid() and u.last_seen >= now() - interval '15 seconds'
  order by mq.created_at asc for update of mq skip locked limit 1;

  if v_opponent_id is null then return null; end if;

  delete from public.matchmaking_queue where user_id = v_opponent_id;
  delete from public.matchmaking_queue where user_id = auth.uid();

  insert into public.matches (game_type, player1_id, player2_id, entry_fee)
  values (p_game_type, v_opponent_id, auth.uid(), p_entry_fee) returning * into v_match;
  return v_match;
end;
$$;
grant execute on function public.claim_opponent(text, integer) to authenticated;

create or replace function public.redeem_referral_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_referrer_id uuid;
  v_me uuid := auth.uid();
  v_already uuid;
begin
  if p_code is null or length(trim(p_code)) = 0 then return json_build_object('success', false, 'message', 'Enter code.'); end if;
  select referred_by into v_already from public.users where id = v_me;
  if v_already is not null then return json_build_object('success', false, 'message', 'Code already redeemed.'); end if;
  select id into v_referrer_id from public.users where referral_code = upper(trim(p_code));
  if v_referrer_id is null then return json_build_object('success', false, 'message', 'Code not found.'); end if;
  if v_referrer_id = v_me then return json_build_object('success', false, 'message', 'Cannot use own code.'); end if;

  update public.users set referred_by = v_referrer_id where id = v_me;
  update public.wallet set dummy_token = dummy_token + 300, updated_at = now() where user_id = v_me;
  update public.wallet set dummy_token = dummy_token + 100, updated_at = now() where user_id = v_referrer_id;
  insert into public.transactions (user_id, description, type, amount) values (v_me, 'Referral bonus redeemed', 'credit', 300);
  insert into public.transactions (user_id, description, type, amount) values (v_referrer_id, 'Referral bonus: friend joined', 'credit', 100);
  return json_build_object('success', true, 'message', 'Referral applied! Received 300 tokens.');
end;
$$;
grant execute on function public.redeem_referral_code(text) to authenticated;
