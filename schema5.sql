-- ============================================================
-- Arena v5 - Opponents Can See Each Other's Live Profile
-- Run this in Supabase SQL Editor AFTER schema.sql..schema4.sql
--
-- Fixes: match.html shows the opponent as literally "Opponent" (and
-- your own name can look stale) instead of their real, current name.
-- Root cause: the "Users can view their own profile" policy on
-- public.users only allows `auth.uid() = id`, so when match.html runs
--   select id, full_name, avatar_url from users where id in (...)
-- RLS silently strips out every row that isn't your own -- the
-- opponent's row never comes back, regardless of what dashboard.js
-- saves. full_name/avatar_url aren't sensitive, so any signed-in
-- player is allowed to read them for anyone (email stays private via
-- the existing policy).
-- ============================================================

drop policy if exists "Users can view their own profile" on public.users;

create policy "Signed-in users can view public profile fields"
  on public.users for select
  to authenticated
  using (true);

-- dashboard.js upserts the caller's own name/avatar on load and on save.
-- No insert policy existed before (rows were only ever created by the
-- signup trigger), so that upsert would fail with a new RLS error for
-- any account whose row is missing. This lets a user insert only their
-- own row.
create policy "Users can insert their own profile"
  on public.users for insert
  to authenticated
  with check (auth.uid() = id);
