-- ============================================================
-- ADMIN: User Investigation Tool (UI PERFECT MATCH)
-- ============================================================

create or replace function public.admin_investigate_user(p_query text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
  v_user record;
  v_wallet integer;
  v_result json;
  v_credits bigint;
  v_debits bigint;
  v_stake_count integer;
  v_stake_sum bigint;
  v_refund_count integer;
  v_refund_sum bigint;
  v_refunds_1h integer;
  v_refunds_24h integer;
  v_wd_count integer;
  v_wd_paid integer;
  v_wd_pending integer;
  v_wd_rejected integer;
  v_matches integer;
  v_wins integer;
  v_losses integer;
  v_draws integer;
  v_sessions_total integer;
  v_sessions_completed integer;
  v_sessions_abandoned integer;
  v_blocks_against integer;
  v_blocks_caused integer;
  v_suspicion_score integer := 0;
  v_flags jsonb := '[]'::jsonb;
  v_activity jsonb := '[]'::jsonb;
  v_is_suspicious boolean := false;
  v_clean_message text := 'No suspicious patterns detected. Account looks clean.';
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden');
  end if;

  if p_query is null or length(trim(p_query)) = 0 then
    return json_build_object('ok', false, 'message', 'Provide email or UUID');
  end if;

  begin
    v_uid := p_query::uuid;
  exception when others then
    v_uid := null;
  end;

  if v_uid is null then
    select id into v_uid from public.users where lower(email) = lower(trim(p_query)) limit 1;
  end if;

  if v_uid is null then
    return json_build_object('ok', false, 'message', 'User not found');
  end if;

  -- Profile & Wallet
  select id, email, full_name, avatar_url, referral_code, referred_by, created_at, last_seen, device_fingerprint, last_ip
    into v_user from public.users where id = v_uid;
  select coalesce(balance, 0) into v_wallet from public.wallet where user_id = v_uid;

  -- Transactions
  select coalesce(sum(case when type='credit' then amount else 0 end), 0), coalesce(sum(case when type='debit'  then amount else 0 end), 0)
    into v_credits, v_debits from public.transactions where user_id = v_uid;

  -- Stakes & Refunds
  select count(*), coalesce(sum(amount), 0) into v_stake_count, v_stake_sum
    from public.transactions where user_id = v_uid and type = 'debit' and description ilike 'Stake%';
    
  select count(*), coalesce(sum(amount), 0) into v_refund_count, v_refund_sum
    from public.transactions where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%';

  select count(*) into v_refunds_1h from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%' and created_at > now() - interval '1 hour';
  select count(*) into v_refunds_24h from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%' and created_at > now() - interval '24 hours';

  -- Withdrawals
  select count(*), count(*) filter (where status = 'paid'), count(*) filter (where status in ('pending','processing')), count(*) filter (where status = 'rejected')
    into v_wd_count, v_wd_paid, v_wd_pending, v_wd_rejected from public.withdrawal_requests where user_id = v_uid;

  -- Matches & Sessions
  select count(*), count(*) filter (where result = 'VICTORY'), count(*) filter (where result = 'DEFEAT'), count(*) filter (where result = 'DRAW')
    into v_matches, v_wins, v_losses, v_draws from public.match_history where user_id = v_uid;

  select count(*), count(*) filter (where status = 'completed'), count(*) filter (where status = 'abandoned')
    into v_sessions_total, v_sessions_completed, v_sessions_abandoned from public.game_sessions where player1_id = v_uid or player2_id = v_uid;

  -- FairPlay
  select count(*) into v_blocks_against from public.fairplay_blocks where user_b = v_uid;
  select count(*) into v_blocks_caused from public.fairplay_blocks where user_a = v_uid;

  -- Suspicion Logic
  if v_stake_count > 0 and (v_refund_count::numeric / v_stake_count::numeric) > 1.5 then
    v_suspicion_score := v_suspicion_score + 40;
    v_flags := v_flags || jsonb_build_object('level', 'critical', 'title', 'Refund ratio abuse', 'detail', 'Has ' || v_refund_count || ' refunds for ' || v_stake_count || ' stakes.');
  end if;

  if v_refunds_1h >= 5 then
    v_suspicion_score := v_suspicion_score + 30;
    v_flags := v_flags || jsonb_build_object('level', 'critical', 'title', 'Refund burst detected', 'detail', v_refunds_1h || ' refunds in the last hour.');
  end if;

  if v_refund_sum > v_stake_sum and v_refund_sum > 0 then
    v_suspicion_score := v_suspicion_score + 30;
    v_flags := v_flags || jsonb_build_object('level', 'critical', 'title', 'Refunds exceed stakes', 'detail', 'Total refunded ₹' || v_refund_sum || ' > total staked ₹' || v_stake_sum);
  end if;

  if v_suspicion_score > 100 then v_suspicion_score := 100; end if;

  -- Set Boolean for UI Red/Green Box
  if v_suspicion_score >= 30 then
    v_is_suspicious := true;
    v_clean_message := '⚠️ ' || jsonb_array_element_text(v_flags, 0)::jsonb->>'title'; -- Grabs the first flag title
  end if;

  -- Activity
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) into v_activity
  from (
    select 'stake' as kind, description as label, amount, type, created_at from public.transactions where user_id = v_uid and description ilike 'Stake%'
    union all
    select 'refund' as kind, description as label, amount, type, created_at from public.transactions where user_id = v_uid and description ilike 'Stake Refunded%'
    union all
    select 'match' as kind, (game || ' · ' || result) as label, reward as amount, null as type, created_at from public.match_history where user_id = v_uid
    union all
    select 'withdrawal' as kind, ('Withdrawal → ' || upi_id) as label, amount, status as type, requested_at as created_at from public.withdrawal_requests where user_id = v_uid
    order by created_at desc limit 30
  ) x;

  -- 🌟 THE UI EXACT MATCH
  v_result := jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', v_user.id, 'email', v_user.email, 'full_name', v_user.full_name, 'avatar_url', v_user.avatar_url,
      'referral_code', v_user.referral_code, 'referred_by', v_user.referred_by,
      'created_at', v_user.created_at, 'last_seen', v_user.last_seen,
      'device_fingerprint', v_user.device_fingerprint, 'last_ip', v_user.last_ip, 'wallet_balance', v_wallet
    ),
    'money', jsonb_build_object(
      'total_credits', v_credits, 'total_debits', v_debits,
      'stake_count', v_stake_count, 'stake_sum', v_stake_sum,
      'refund_count', v_refund_count, 'refund_sum', v_refund_sum,
      'refunds_1h', v_refunds_1h, 'refunds_24h', v_refunds_24h,
      'refund_ratio', case when v_stake_count > 0 then round(v_refund_count::numeric / v_stake_count::numeric, 2) else 0 end
    ),
    'matches', jsonb_build_object(
      'total', v_matches, 'wins', v_wins, 'losses', v_losses, 'draws', v_draws,
      'win_rate', case when v_matches > 0 then round((v_wins::numeric / v_matches::numeric) * 100) else 0 end
    ),
    'sessions', jsonb_build_object('total', v_sessions_total, 'completed', v_sessions_completed, 'abandoned', v_sessions_abandoned),
    'withdrawals', jsonb_build_object('total', v_wd_count, 'paid', v_wd_paid, 'pending', v_wd_pending, 'rejected', v_wd_rejected),
    'fairplay', jsonb_build_object('blocks_against', v_blocks_against, 'blocks_caused', v_blocks_caused),
    
    -- 🌟 SUSPICION DETECTION (Wired into the UI)
    'suspicion', jsonb_build_object(
      'score', v_suspicion_score, 
      'level', case when v_suspicion_score >= 60 then 'high' when v_suspicion_score >= 30 then 'medium' when v_suspicion_score > 0 then 'low' else 'clean' end,
      'flags', v_flags,
      'is_suspicious', v_is_suspicious,   -- The boolean your UI needs
      'message', v_clean_message          -- The text your UI needs
    ),
    'activity', v_activity
  );

  return v_result;
end; $$;

grant execute on function public.admin_investigate_user(text) to authenticated;
