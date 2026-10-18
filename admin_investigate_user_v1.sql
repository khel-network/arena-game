-- ============================================================
-- ADMIN: User Investigation Tool v6.0 (UI Matched + Deep Math)
-- ============================================================

create or replace function public.admin_investigate_user(p_query text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid;
  v_user record;
  v_wallet integer;
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
  v_warning_message text := '';
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

  select id, email, full_name, avatar_url, referral_code, referred_by,
         created_at, last_seen, device_fingerprint, last_ip
    into v_user
    from public.users where id = v_uid;

  select coalesce(balance, 0) into v_wallet from public.wallet where user_id = v_uid;

  select coalesce(sum(case when type='credit' then amount else 0 end), 0),
         coalesce(sum(case when type='debit'  then amount else 0 end), 0)
    into v_credits, v_debits
    from public.transactions where user_id = v_uid;

  select count(*), coalesce(sum(amount), 0)
    into v_stake_count, v_stake_sum
    from public.transactions
    where user_id = v_uid and type = 'debit' and description ilike 'Stake%';

  select count(*), coalesce(sum(amount), 0)
    into v_refund_count, v_refund_sum
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%';

  select count(*) into v_refunds_1h
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%' and created_at > now() - interval '1 hour';

  select count(*) into v_refunds_24h
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%' and created_at > now() - interval '24 hours';

  select count(*),
         count(*) filter (where status = 'paid'),
         count(*) filter (where status in ('pending','processing')),
         count(*) filter (where status = 'rejected')
    into v_wd_count, v_wd_paid, v_wd_pending, v_wd_rejected
    from public.withdrawal_requests where user_id = v_uid;

  select count(*),
         count(*) filter (where result = 'VICTORY'),
         count(*) filter (where result = 'DEFEAT'),
         count(*) filter (where result = 'DRAW')
    into v_matches, v_wins, v_losses, v_draws
    from public.match_history where user_id = v_uid;

  select count(*),
         count(*) filter (where status = 'completed'),
         count(*) filter (where status = 'abandoned')
    into v_sessions_total, v_sessions_completed, v_sessions_abandoned
    from public.game_sessions
    where player1_id = v_uid or player2_id = v_uid;

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

  -- Set the boolean for the UI Green/Red Box
  if v_suspicion_score >= 30 then
    v_is_suspicious := true;
    v_warning_message := 'Account flagged. Suspicion score: ' || v_suspicion_score || '/100';
  else
    v_is_suspicious := false;
    v_warning_message := 'No suspicious patterns detected. Account looks clean.';
  end if;

  -- Activity timeline
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) into v_activity
  from (
    select 'stake' as kind, description as label, amount, type, created_at
    from public.transactions where user_id = v_uid and description ilike 'Stake%'
    union all
    select 'refund' as kind, description as label, amount, type, created_at
    from public.transactions where user_id = v_uid and description ilike 'Stake Refunded%'
    union all
    select 'match' as kind, (game || ' · ' || result) as label, reward as amount, null as type, created_at
    from public.match_history where user_id = v_uid
    union all
    select 'withdrawal' as kind, ('Withdrawal → ' || upi_id) as label, amount, status as type, requested_at as created_at
    from public.withdrawal_requests where user_id = v_uid
    order by created_at desc
    limit 30
  ) x;

  -- THIS IS THE MAGIC FIX: Returning the exact JSON structure your UI expects
  return json_build_object(
    'ok', true,
    'user', jsonb_build_object(
      'id', v_user.id, 'email', v_user.email, 'full_name', v_user.full_name, 
      'joined_at', v_user.created_at, 'last_seen', v_user.last_seen,
      'fingerprint', v_user.device_fingerprint, 'last_ip', v_user.last_ip,
      'referral_code', v_user.referral_code, 'referred_by', v_user.referred_by
    ),
    'wallet', jsonb_build_object(
      'balance', v_wallet,
      'real_earnings', (select coalesce(real_earnings, 0) from public.wallet where user_id = v_uid),
      'suspicious_funds', (v_wallet - (select coalesce(real_earnings, 0) from public.wallet where user_id = v_uid)),
      'total_credits', v_credits,
      'total_debits', v_debits
    ),
    'stats', jsonb_build_object(
      'total_stakes', v_stake_count, 'stakes', v_stake_count,
      'total_refunds', v_refund_count, 'refunds', v_refund_count,
      'refunds_24h', v_refunds_24h, 'refunds_recent', v_refunds_24h,
      'fairplay_blocks', v_blocks_caused,
      'sessions_completed', v_sessions_completed,
      'sessions_abandoned', v_sessions_abandoned,
      'total_matches', v_matches, 'matches', v_matches,
      'total_wins', v_wins, 'wins', v_wins,
      'withdrawals', v_wd_count
    ),
    'suspicious_detection', jsonb_build_object(
      'is_suspicious', v_is_suspicious,
      'message', v_warning_message
    ),
    'activity', v_activity
  );
end; $$;

grant execute on function public.admin_investigate_user(text) to authenticated;
