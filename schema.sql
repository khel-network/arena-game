-- ============================================================
-- Arena Prototype - Database Schema
-- Run this entire file in Supabase Dashboard > SQL Editor
-- ============================================================

-- 1. PUBLIC PROFILE TABLE
create table if not exists public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.users enable row level security;

create policy "Users can view their own profile"
  on public.users for select
  using (auth.uid() = id);

create policy "Users can update their own profile"
  on public.users for update
  using (auth.uid() = id);

-- 2. WALLET TABLE
create table if not exists public.wallet (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.users (id) on delete cascade,
  dummy_token integer not null default 1000 check (dummy_token >= 0),
  updated_at timestamptz not null default now()
);

alter table public.wallet enable row level security;

create policy "Users can view their own wallet"
  on public.wallet for select
  using (auth.uid() = user_id);

-- 3. AUTO-PROVISION NEW USERS
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  );

  insert into public.wallet (user_id, dummy_token)
  values (new.id, 1000);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
