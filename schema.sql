-- ============================================================
-- SkillClash v9 - Delivery 1
-- Adds: match_invites (realtime), terms acceptance tracking
-- ============================================================

-- 1) Track terms + age acceptance on users
alter table public.users add column if not exists terms_accepted_at timestamptz;
alter table public.users add column if not exists age_confirmed boolean not null default false;

-- 2) Match invites — a lightweight realtime broadcast that a player
--    is waiting in queue, so others on the dashboard can join them.
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

-- 3) Realtime for match_invites
do $$
begin
  begin
    alter publication supabase_realtime add table public.match_invites;
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;

-- 4) Auto-expire old invites (called by the client every few seconds
--    or run as a cron). Cheap to run, keeps the table tiny.
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

-- 5) Accept an invite — atomic, safe from races
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
