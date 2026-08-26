-- ============================================================
-- Arena v4 - Atomic Real-Opponent Matching
-- Run this in Supabase SQL Editor AFTER schema.sql, schema2.sql, schema3.sql
--
-- Fixes: two real accounts playing at the same time always got matched
-- with a bot instead of each other. Root cause: the "Users can leave
-- the queue" RLS policy only lets a user delete THEIR OWN queue row.
-- When Account B tried to claim Account A's waiting row (delete it,
-- then create the match), RLS silently blocked that delete because it
-- wasn't Account B's own row -- so the claim always failed and both
-- accounts fell through to a bot after the 5s wait, regardless of any
-- client-side polling logic.
--
-- This function does the whole "find a waiting opponent -> lock their
-- row -> remove them from the queue -> create the match" sequence in
-- one atomic, server-side transaction that runs with elevated rights
-- (security definer), so it isn't blocked by the per-row RLS policy,
-- and "for update skip locked" means two players polling at the exact
-- same instant can never both claim the same opponent.
-- ============================================================

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
  -- Find the longest-waiting opponent for this game type (not myself),
  -- and lock that row so no other concurrent call can grab the same one.
  select user_id into v_opponent
  from public.matchmaking_queue
  where game_type = p_game_type
    and user_id <> auth.uid()
  order by created_at asc
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
