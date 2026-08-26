-- ============================================================
-- Arena v6 - Refer & Earn Program
-- Run this in Supabase SQL Editor AFTER schema.sql..schema5.sql
--
-- Fixes: the Refer & Earn screen shows "Unavailable" and redeeming a
-- code always fails. Root cause: dashboard.js already reads/writes a
-- `referral_code` column and calls a `redeem_referral_code()` function,
-- but neither one existed anywhere in the database yet.
--
-- This adds:
--   1. referral_code column (each user's own shareable code)
--   2. referred_by column (tracks who invited this user, one-time use)
--   3. redeem_referral_code(p_code) - validates the code, blocks reuse
--      and self-referral, then credits both wallets atomically and
--      logs both sides in the transactions ledger.
-- ============================================================

-- 1. New columns on the existing users table
alter table public.users add column if not exists referral_code text unique;
alter table public.users add column if not exists referred_by uuid references public.users (id);

-- 2. Redemption function
create or replace function public.redeem_referral_code(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_referrer_id uuid;
  v_already_used boolean;
begin
  if p_code is null or length(trim(p_code)) = 0 then
    return json_build_object('success', false, 'message', 'Please enter a referral code.');
  end if;

  -- Block reusing a referral more than once per account.
  select referred_by is not null into v_already_used
  from public.users
  where id = auth.uid();

  if v_already_used then
    return json_build_object('success', false, 'message', 'You have already redeemed a referral code.');
  end if;

  -- Find who owns this code.
  select id into v_referrer_id
  from public.users
  where referral_code = upper(trim(p_code));

  if v_referrer_id is null then
    return json_build_object('success', false, 'message', 'That referral code doesn''t exist.');
  end if;

  if v_referrer_id = auth.uid() then
    return json_build_object('success', false, 'message', 'You cannot use your own referral code.');
  end if;

  -- Mark this account as referred (locks out future redemptions).
  update public.users set referred_by = v_referrer_id where id = auth.uid();

  -- Credit both wallets: new user gets 300, referrer gets 100.
  update public.wallet set dummy_token = dummy_token + 300, updated_at = now() where user_id = auth.uid();
  update public.wallet set dummy_token = dummy_token + 100, updated_at = now() where user_id = v_referrer_id;

  -- Ledger entries for both sides.
  insert into public.transactions (user_id, description, type, amount) values
    (auth.uid(), 'Referral Bonus: Joined using a referral code', 'credit', 300),
    (v_referrer_id, 'Referral Bonus: A friend joined using your code', 'credit', 100);

  return json_build_object('success', true, 'message', 'Referral applied! You received \u20b9300 in tokens.');
end;
$$;

grant execute on function public.redeem_referral_code(text) to authenticated;

-- ============================================================
-- After running this, open the Refer & Earn screen once per account
-- to auto-generate that account's own referral_code (dashboard.js
-- already does this on load), then test redeeming it from a second
-- account.
-- ============================================================
