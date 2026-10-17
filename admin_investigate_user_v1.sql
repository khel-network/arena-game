-- ============================================================
-- ADMIN INVESTIGATE USER v2.1 (Fixes UI Parameter Mismatch)
-- ============================================================

-- 1. Drop the old function to prevent caching/parameter conflicts
drop function if exists public.admin_investigate_user(text);

-- 2. Create the new updated function using 'p_query' to match your UI
create or replace function public.admin_investigate_user(p_query text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_user record;
  v_wallet record;
  v_stats json;
  v_recent_tx json;
  v_total_refunds integer;
  v_refunds_24h integer;
  v_is_suspicious boolean := false;
  v_warning_message text := '';
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden');
  end if;

  -- Find user by email or UUID using the 'p_query' parameter
  select * into v_user from public.users 
  where email = p_query or id::text = p_query limit 1;
  
  if v_user is null then 
    return json_build_object('ok', false, 'message', 'User not found'); 
  end if;

  select * into v_wallet from public.wallet where user_id = v_user.id;

  -- Count all refunds
  select count(*) into v_total_refunds from public.transactions 
  where user_id = v_user.id and type = 'credit' and description ilike 'Stake Refunded%';

  -- Count refunds in the last 24 hours
  select count(*) into v_refunds_24h from public.transactions 
  where user_id = v_user.id and type = 'credit' and description ilike 'Stake Refunded%' and created_at > now() - interval '24 hours';

  -- 🚨 SUSPICIOUS PATTERN CHECKS
  if v_total_refunds >= 3 then
    v_is_suspicious := true;
    v_warning_message := 'Refund farming detected: ' || v_total_refunds || ' total refunds.';
  end if;

  if v_refunds_24h >= 3 then
    v_is_suspicious := true;
    v_warning_message := 'High volume: ' || v_refunds_24h || ' refunds in the last 24 hours.';
  end if;

  if (coalesce(v_wallet.balance, 0) - coalesce(v_wallet.real_earnings, 0)) > 100 then
    v_is_suspicious := true;
    v_warning_message := 'High non-withdrawable balance detected (Fake money from refunds).';
  end if;

  -- Get recent transactions
  select coalesce(json_agg(t), '[]'::json) into v_recent_tx
  from (
    select description, type, amount, to_char(created_at at time zone 'Asia/Kolkata', 'DD Mon HH12:MI AM') as date 
    from public.transactions 
    where user_id = v_user.id 
    order by created_at desc limit 10
  ) t;

  -- Compile stats
  select json_build_object(
    'total_matches', (select count(*) from public.match_history where user_id = v_user.id),
    'wins', (select count(*) from public.match_history where user_id = v_user.id and result = 'VICTORY'),
    'refunds_total', v_total_refunds,
    'refunds_24h', v_refunds_24h,
    'fairplay_blocks', (select count(*) from public.fairplay_blocks where user_a = v_user.id or user_b = v_user.id)
  ) into v_stats;

  -- Return final JSON
  return json_build_object(
    'ok', true,
    'user', json_build_object(
      'id', v_user.id, 'email', v_user.email, 'full_name', v_user.full_name, 
      'joined_at', v_user.created_at, 'last_seen', v_user.last_seen,
      'fingerprint', v_user.device_fingerprint, 'last_ip', v_user.last_ip
    ),
    'wallet', json_build_object(
      'balance', coalesce(v_wallet.balance, 0),
      'real_earnings', coalesce(v_wallet.real_earnings, 0),
      'suspicious_funds', (coalesce(v_wallet.balance, 0) - coalesce(v_wallet.real_earnings, 0))
    ),
    'stats', v_stats,
    'suspicious_detection', json_build_object(
      'is_suspicious', v_is_suspicious,
      'message', case when v_is_suspicious then v_warning_message else 'Account looks clean. No refund abuse detected.' end
    ),
    'recent_transactions', v_recent_tx
  );
end; $$;

grant execute on function public.admin_investigate_user(text) to authenticated;
