-- ============================================================
-- ADMIN: User Investigation Tool
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
  v_blocks_against integer;   -- times THEY were blocked (fairplay_blocks.user_b)
  v_blocks_caused integer;    -- times they caused a block (fairplay_blocks.user_a)
  v_suspicion_score integer := 0;
  v_flags jsonb := '[]'::jsonb;
  v_activity jsonb := '[]'::jsonb;
begin
  -- Admin check
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden');
  end if;

  if p_query is null or length(trim(p_query)) = 0 then
    return json_build_object('ok', false, 'message', 'Provide email or UUID');
  end if;

  -- Try UUID first
  begin
    v_uid := p_query::uuid;
  exception when others then
    v_uid := null;
  end;

  -- If not UUID, look up by email
  if v_uid is null then
    select id into v_uid from public.users where lower(email) = lower(trim(p_query)) limit 1;
  end if;

  if v_uid is null then
    return json_build_object('ok', false, 'message', 'User not found');
  end if;

  -- Profile
  select id, email, full_name, avatar_url, referral_code, referred_by,
         created_at, last_seen, device_fingerprint, last_ip
    into v_user
    from public.users where id = v_uid;

  select coalesce(balance, 0) into v_wallet from public.wallet where user_id = v_uid;

  -- Wallet flows
  select coalesce(sum(case when type='credit' then amount else 0 end), 0),
         coalesce(sum(case when type='debit'  then amount else 0 end), 0)
    into v_credits, v_debits
    from public.transactions where user_id = v_uid;

  -- Stakes
  select count(*), coalesce(sum(amount), 0)
    into v_stake_count, v_stake_sum
    from public.transactions
    where user_id = v_uid and type = 'debit' and description ilike 'Stake%';

  -- Refunds
  select count(*), coalesce(sum(amount), 0)
    into v_refund_count, v_refund_sum
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%';

  select count(*) into v_refunds_1h
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%'
      and created_at > now() - interval '1 hour';

  select count(*) into v_refunds_24h
    from public.transactions
    where user_id = v_uid and type = 'credit' and description ilike 'Stake Refunded%'
      and created_at > now() - interval '24 hours';

  -- Withdrawals
  select count(*),
         count(*) filter (where status = 'paid'),
         count(*) filter (where status in ('pending','processing')),
         count(*) filter (where status = 'rejected')
    into v_wd_count, v_wd_paid, v_wd_pending, v_wd_rejected
    from public.withdrawal_requests where user_id = v_uid;

  -- Match history
  select count(*),
         count(*) filter (where result = 'VICTORY'),
         count(*) filter (where result = 'DEFEAT'),
         count(*) filter (where result = 'DRAW')
    into v_matches, v_wins, v_losses, v_draws
    from public.match_history where user_id = v_uid;

  -- Sessions
  select count(*),
         count(*) filter (where status = 'completed'),
         count(*) filter (where status = 'abandoned')
    into v_sessions_total, v_sessions_completed, v_sessions_abandoned
    from public.game_sessions
    where player1_id = v_uid or player2_id = v_uid;

  -- FairPlay blocks
  select count(*) into v_blocks_against
    from public.fairplay_blocks where user_b = v_uid;
  select count(*) into v_blocks_caused
    from public.fairplay_blocks where user_a = v_uid;

  -- Suspicious pattern detection
  -- Pattern A: Refund ratio too high (refunds per stake > 1.5)
  if v_stake_count > 0 and (v_refund_count::numeric / v_stake_count::numeric) > 1.5 then
    v_suspicion_score := v_suspicion_score + 40;
    v_flags := v_flags || jsonb_build_object(
      'level', 'critical',
      'title', 'Refund ratio abuse',
      'detail', 'Has ' || v_refund_count || ' refunds for only ' || v_stake_count || ' stakes (ratio ' || round(v_refund_count::numeric / v_stake_count::numeric, 2) || '). Expected ~1.0.'
    );
  elsif v_stake_count > 0 and (v_refund_count::numeric / v_stake_count::numeric) > 1.2 then
    v_suspicion_score := v_suspicion_score + 20;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'Elevated refund ratio',
      'detail', v_refund_count || ' refunds for ' || v_stake_count || ' stakes.'
    );
  end if;

  -- Pattern B: Burst of refunds in short window
  if v_refunds_1h >= 5 then
    v_suspicion_score := v_suspicion_score + 30;
    v_flags := v_flags || jsonb_build_object(
      'level', 'critical',
      'title', 'Refund burst detected',
      'detail', v_refunds_1h || ' refunds in the last hour. Normal play does not produce this.'
    );
  elsif v_refunds_24h >= 10 then
    v_suspicion_score := v_suspicion_score + 15;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'High refund volume (24h)',
      'detail', v_refunds_24h || ' refunds in 24 hours.'
    );
  end if;

  -- Pattern C: Many sessions but zero completed matches
  if v_sessions_total >= 5 and v_sessions_completed = 0 and v_matches = 0 then
    v_suspicion_score := v_suspicion_score + 25;
    v_flags := v_flags || jsonb_build_object(
      'level', 'critical',
      'title', 'No completed matches',
      'detail', v_sessions_total || ' sessions started but 0 completed matches. Likely exploiting refund flow.'
    );
  end if;

  -- Pattern D: Wallet gained more than they should have
  if v_wallet > 100 and v_stake_count < 5 then
    v_suspicion_score := v_suspicion_score + 20;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'High balance, low activity',
      'detail', 'Wallet has ' || v_wallet || ' but only ' || v_stake_count || ' stakes ever placed.'
    );
  end if;

  -- Pattern E: Abandoned rate too high
  if v_sessions_total >= 5 and (v_sessions_abandoned::numeric / v_sessions_total::numeric) > 0.7 then
    v_suspicion_score := v_suspicion_score + 15;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'Frequent abandoned matches',
      'detail', v_sessions_abandoned || ' of ' || v_sessions_total || ' sessions were abandoned.'
    );
  end if;

  -- Pattern F: Many FairPlay blocks
  if v_blocks_against >= 3 then
    v_suspicion_score := v_suspicion_score + 20;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'Repeatedly flagged by FairPlay',
      'detail', 'This account has been blocked ' || v_blocks_against || ' times by FairPlay.'
    );
  end if;

  if v_blocks_caused >= 3 then
    v_suspicion_score := v_suspicion_score + 10;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'Triggers FairPlay often',
      'detail', 'This account has caused ' || v_blocks_caused || ' FairPlay blocks against other users.'
    );
  end if;

  -- Pattern G: Multiple withdrawals in short window
  if v_wd_count >= 3 and v_wd_pending >= 2 then
    v_suspicion_score := v_suspicion_score + 15;
    v_flags := v_flags || jsonb_build_object(
      'level', 'warning',
      'title', 'Multiple pending withdrawals',
      'detail', v_wd_pending || ' withdrawal requests currently pending.'
    );
  end if;

  -- Pattern H: Refund credits exceed stake debits (net gain from refunds)
  if v_refund_sum > v_stake_sum and v_refund_sum > 0 then
    v_suspicion_score := v_suspicion_score + 30;
    v_flags := v_flags || jsonb_build_object(
      'level', 'critical',
      'title', 'Refunds exceed stakes',
      'detail', 'Total refunded ₹' || v_refund_sum || ' > total staked ₹' || v_stake_sum || '. Wallet grew without winning.'
    );
  end if;

  -- Cap at 100
  if v_suspicion_score > 100 then v_suspicion_score := 100; end if;

  -- Recent activity timeline (combined last 30 events)
  select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb) into v_activity
  from (
    select 'stake' as kind, description as label, amount, type, created_at
    from public.transactions
    where user_id = v_uid and description ilike 'Stake%'
    union all
    select 'refund' as kind, description as label, amount, type, created_at
    from public.transactions
    where user_id = v_uid and description ilike 'Stake Refunded%'
    union all
    select 'match' as kind, (game || ' · ' || result) as label, reward as amount, null as type, created_at
    from public.match_history
    where user_id = v_uid
    union all
    select 'withdrawal' as kind, ('Withdrawal → ' || upi_id) as label, amount, status as type, requested_at as created_at
    from public.withdrawal_requests
    where user_id = v_uid
    order by created_at desc
    limit 30
  ) x;

  -- Build result
  v_result := jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'id', v_user.id,
      'email', v_user.email,
      'full_name', v_user.full_name,
      'avatar_url', v_user.avatar_url,
      'referral_code', v_user.referral_code,
      'referred_by', v_user.referred_by,
      'created_at', v_user.created_at,
      'last_seen', v_user.last_seen,
      'device_fingerprint', v_user.device_fingerprint,
      'last_ip', v_user.last_ip,
      'wallet_balance', v_wallet
    ),
    'money', jsonb_build_object(
      'total_credits', v_credits,
      'total_debits', v_debits,
      'stake_count', v_stake_count,
      'stake_sum', v_stake_sum,
      'refund_count', v_refund_count,
      'refund_sum', v_refund_sum,
      'refunds_1h', v_refunds_1h,
      'refunds_24h', v_refunds_24h,
      'refund_ratio', case when v_stake_count > 0 then round(v_refund_count::numeric / v_stake_count::numeric, 2) else 0 end
    ),
    'matches', jsonb_build_object(
      'total', v_matches,
      'wins', v_wins,
      'losses', v_losses,
      'draws', v_draws,
      'win_rate', case when v_matches > 0 then round((v_wins::numeric / v_matches::numeric) * 100) else 0 end
    ),
    'sessions', jsonb_build_object(
      'total', v_sessions_total,
      'completed', v_sessions_completed,
      'abandoned', v_sessions_abandoned
    ),
    'withdrawals', jsonb_build_object(
      'total', v_wd_count,
      'paid', v_wd_paid,
      'pending', v_wd_pending,
      'rejected', v_wd_rejected
    ),
    'fairplay', jsonb_build_object(
      'blocks_against', v_blocks_against,
      'blocks_caused', v_blocks_caused
    ),
    'suspicion', jsonb_build_object(
      'score', v_suspicion_score,
      'level', case
        when v_suspicion_score >= 60 then 'high'
        when v_suspicion_score >= 30 then 'medium'
        when v_suspicion_score > 0 then 'low'
        else 'clean'
      end,
      'flags', v_flags
    ),
    'activity', v_activity
  );

  return v_result;
end; $$;

grant execute on function public.admin_investigate_user(text) to authenticated;
