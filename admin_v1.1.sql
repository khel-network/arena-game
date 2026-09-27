-- ============================================================
-- ADMIN SYSTEM v1.1 — with Vishal pre-registered as super_admin
-- ============================================================

-- 1. Admins table
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'admin' check (role in ('admin', 'super_admin', 'moderator')),
  added_at timestamptz not null default now()
);

alter table public.admins enable row level security;

drop policy if exists "Admins can view admin list" on public.admins;
create policy "Admins can view admin list"
  on public.admins for select
  using (auth.uid() in (select user_id from public.admins));

-- 2. Helper: is_admin
create or replace function public.is_admin()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
grant execute on function public.is_admin() to authenticated;

-- 3. Helper: get_admin_role
create or replace function public.get_admin_role()
returns text language sql security definer stable
set search_path = public as $$
  select role from public.admins where user_id = auth.uid();
$$;
grant execute on function public.get_admin_role() to authenticated;

-- 4. Lockdown: send_notification (admin only)
create or replace function public.send_notification(
  p_title text,
  p_body text default null,
  p_user_id uuid default null,
  p_type text default 'general',
  p_icon text default 'bell'
)
returns json language plpgsql security definer set search_path = public as $$
declare v_count integer := 0;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden: admin only');
  end if;

  if p_title is null or length(trim(p_title)) = 0 then
    return json_build_object('ok', false, 'message', 'Title required.');
  end if;

  if p_user_id is not null then
    insert into public.notifications (user_id, title, body, type, icon)
    values (p_user_id, p_title, p_body, p_type, p_icon);
    v_count := 1;
  else
    insert into public.notifications (user_id, title, body, type, icon)
    select u.id, p_title, p_body, p_type, p_icon
    from public.users u;
    get diagnostics v_count = row_count;
  end if;

  return json_build_object('ok', true, 'sent', v_count);
end; $$;

grant execute on function public.send_notification(text, text, uuid, text, text) to authenticated;

-- 5. Lockdown: admin_send_broadcast
create or replace function public.admin_send_broadcast(
  p_title text, p_body text default null,
  p_type text default 'promo', p_icon text default 'bell'
)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden: admin only');
  end if;
  return public.send_notification(p_title, p_body, null, p_type, p_icon);
end; $$;

grant execute on function public.admin_send_broadcast(text, text, text, text) to authenticated;

-- 6. Admin stats RPC
create or replace function public.admin_get_stats()
returns json language plpgsql security definer set search_path = public as $$
declare
  v_users integer;
  v_active_today integer;
  v_total_balance bigint;
  v_matches_today integer;
  v_pending_withdrawals integer;
  v_pending_withdrawals_amount bigint;
  v_revenue_today bigint;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden');
  end if;

  select count(*) into v_users from public.users;
  select count(*) into v_active_today from public.users where last_seen > now() - interval '24 hours';
  select coalesce(sum(balance), 0) into v_total_balance from public.wallet;
  select count(*) into v_matches_today from public.game_sessions where created_at > now() - interval '24 hours';
  select count(*), coalesce(sum(amount), 0) into v_pending_withdrawals, v_pending_withdrawals_amount
    from public.withdrawal_requests where status in ('pending', 'processing');
  select coalesce(sum(entry_fee), 0) into v_revenue_today from public.game_sessions
    where created_at > now() - interval '24 hours' and status = 'completed';

  return json_build_object(
    'ok', true,
    'users', v_users,
    'active_today', v_active_today,
    'total_balance', v_total_balance,
    'matches_today', v_matches_today,
    'pending_withdrawals', v_pending_withdrawals,
    'pending_withdrawals_amount', v_pending_withdrawals_amount,
    'revenue_today', v_revenue_today
  );
end; $$;

grant execute on function public.admin_get_stats() to authenticated;

-- 7. Admin: get recent users list
create or replace function public.admin_get_users(p_limit integer default 50)
returns table (
  id uuid, email text, full_name text, referral_code text,
  balance integer, total_matches integer, total_wins integer,
  last_seen timestamptz, created_at timestamptz
) language sql security definer set search_path = public as $$
  select u.id, u.email, u.full_name, u.referral_code,
         coalesce(w.balance, 0) as balance,
         coalesce((select count(*) from public.match_history mh where mh.user_id = u.id), 0) as total_matches,
         coalesce((select count(*) from public.match_history mh where mh.user_id = u.id and mh.result = 'VICTORY'), 0) as total_wins,
         u.last_seen, u.created_at
  from public.users u
  left join public.wallet w on w.user_id = u.id
  where public.is_admin()
  order by u.created_at desc
  limit least(p_limit, 200);
$$;

grant execute on function public.admin_get_users(integer) to authenticated;

-- 8. Admin: get pending withdrawals
create or replace function public.admin_get_pending_withdrawals()
returns table (
  id uuid, user_id uuid, full_name text, email text, upi_id text,
  amount integer, status text, requested_at timestamptz
) language sql security definer set search_path = public as $$
  select id, user_id, full_name, email, upi_id, amount, status, requested_at
  from public.withdrawal_requests
  where status in ('pending', 'processing') and public.is_admin()
  order by requested_at asc
  limit 100;
$$;

grant execute on function public.admin_get_pending_withdrawals() to authenticated;

-- 9. Admin: get recent transactions
create or replace function public.admin_get_recent_transactions(p_limit integer default 50)
returns table (
  id uuid, user_id uuid, full_name text, description text, type text,
  amount integer, created_at timestamptz
) language sql security definer set search_path = public as $$
  select t.id, t.user_id, u.full_name, t.description, t.type, t.amount, t.created_at
  from public.transactions t
  left join public.users u on u.id = t.user_id
  where public.is_admin()
  order by t.created_at desc
  limit least(p_limit, 200);
$$;

grant execute on function public.admin_get_recent_transactions(integer) to authenticated;

-- 10. Admin: adjust any user's wallet balance
create or replace function public.admin_adjust_balance(
  p_user_id uuid, p_delta integer, p_reason text default null
)
returns json language plpgsql security definer set search_path = public as $$
declare v_new integer;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'message', 'Forbidden');
  end if;
  if p_delta = 0 then
    return json_build_object('ok', false, 'message', 'Delta cannot be zero');
  end if;

  update public.wallet
    set balance = greatest(0, balance + p_delta), updated_at = now()
    where user_id = p_user_id
    returning balance into v_new;

  if v_new is null then
    return json_build_object('ok', false, 'message', 'User wallet not found');
  end if;

  insert into public.transactions (user_id, description, type, amount)
  values (p_user_id,
          coalesce(p_reason, 'Admin adjustment'),
          case when p_delta > 0 then 'credit' else 'debit' end,
          abs(p_delta));

  return json_build_object('ok', true, 'new_balance', v_new);
end; $$;

grant execute on function public.admin_adjust_balance(uuid, integer, text) to authenticated;

-- 11. Close the notifications RLS hole
drop policy if exists "Users insert own notifications" on public.notifications;
create policy "Users insert own notifications"
  on public.notifications for insert
  with check (user_id = auth.uid());

drop policy if exists "Users view own notifications" on public.notifications;
create policy "Users view own notifications"
  on public.notifications for select
  using (user_id = auth.uid());

-- ============================================================
-- 12. 👑 REGISTER VISHAL AS SUPER_ADMIN (already filled in)
-- ============================================================
insert into public.admins (user_id, email, full_name, role)
values (
  '9cf948d5-5d59-4f73-9777-ac02fe53eed3',
  'vishalkashyap7424@gmail.com',
  'vishal',
  'super_admin'
)
on conflict (user_id) do update set
  email = excluded.email,
  full_name = excluded.full_name,
  role = excluded.role;

-- ============================================================
-- DONE ✅
-- Verify with:  select * from public.admins;
-- Expected: 1 row with vishalkashyap7424@gmail.com, role=super_admin
-- ============================================================
