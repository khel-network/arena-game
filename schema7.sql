-- ============================================================
-- Arena v7 - Real Online-Presence Matchmaking
-- Run this in Supabase SQL Editor AFTER schema.sql..schema6.sql
--
-- Fixes: matchmaking could pair you with an account that isn't
-- actually online right now (e.g. one of your own other accounts
-- that queued for a game weeks ago and simply closed the tab).
-- Root cause: a row in matchmaking_queue was treated as "a live
-- player waiting" forever, with nothing checking whether that
-- account still had the site open. claim_opponent() (schema4.sql)
-- would happily hand out a match to a queue row that had been sitting
-- there since the account's last visit.
--
-- This adds:
--   1. last_seen column on public.users - a heartbeat timestamp the
--      dashboard now updates every few seconds while it's open
--      (see dashboard.js touchPresence()).
--   2. claim_opponent() is updated to FIRST delete any queue rows
--      belonging to accounts that haven't sent a heartbeat recently
--      (i.e. are not actually online), and to only ever hand out a
--      match to an opponent whose last_seen is fresh. That guarantees
--      the 5-second "waiting for a live player" timer in dashboard.js
--      can only ever match you with someone genuinely online right
--      now - anyone else falls through to the bot fallback exactly
--      like the client-side timer already intends.
-- ============================================================

-- 1. Heartbeat column
alter table public.users add column if not exists last_seen timestamptz;

-- How long a heartbeat stays valid before an account is considered
-- offline. dashboard.js sends a heartbeat every ~8s, so 15s comfortably
-- survives one missed beat without ever matching a truly-gone player.
-- (Kept as a literal interval below so it's easy to find/tune.)

-- 2. Presence-aware claim_opponent (same signature as schema4.sql,
-- CREATE OR REPLACE simply upgrades it in place).
create or replace function public.claim_opponent(p_game_type text, p_entry_fee integer)
returns public.matches
language plpgsql
security definer
set search_path = public
as $$
declare
  v_opponent uuid;
  v_match public.matches;
begin
  -- Purge queue rows for anyone who isn't actually online anymore
  -- (no heartbeat, or one older than 15s) before we even look for an
  -- opponent. This is what stops a long-abandoned queue row - from
  -- this account or any other - from ever being offered as a "live"
  -- match again.
  delete from public.matchmaking_queue mq
  using public.users u
  where mq.user_id = u.id
    and (u.last_seen is null or u.last_seen < now() - interval '15 seconds');

  -- Find the longest-waiting opponent for this game type (not myself)
  -- who is still genuinely online, and lock that row so no other
  -- concurrent call can grab the same one.
  select mq.user_id into v_opponent
  from public.matchmaking_queue mq
  join public.users u on u.id = mq.user_id
  where mq.game_type = p_game_type
    and mq.user_id <> auth.uid()
    and u.last_seen >= now() - interval '15 seconds'
  order by mq.created_at asc
  limit 1
  for update skip locked;

  if v_opponent is null then
    return null;
  end if;

  delete from public.matchmaking_queue where user_id = v_opponent;

  insert into public.matches (game_type, player1_id, player2_id, entry_fee)
  values (p_game_type, v_opponent, auth.uid(), p_entry_fee)
  returning * into v_match;

  return v_match;
end;
$$;

grant execute on function public.claim_opponent(text, integer) to authenticated;

-- ============================================================
-- After running this, dashboard.js's heartbeat (every ~8s while the
-- dashboard is open) keeps last_seen fresh for genuinely active
-- players, and offline accounts - including any of your own other
-- accounts that aren't actually open right now - can no longer be
-- claimed as a "live opponent". They fall straight through to the
-- bot fallback after the usual 5-second wait.
-- ============================================================
