-- SoFlo Wheelie Life - admin tools
-- Run in Supabase > SQL Editor. Safe to run more than once.
--
-- The client has a passphrase, but that is only a door that reveals the panel.
-- Every actual power is checked here against this table, so a player who finds
-- the passphrase in the page source gets a panel where nothing works.

create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

drop policy if exists "admins readable" on public.admins;
-- everyone may check whether they themselves are an admin; nobody may write
create policy "admins readable" on public.admins for select using (auth.uid() = user_id);

-- security definer so it can read the table regardless of the caller's own policies
create or replace function public.is_admin() returns boolean
  language sql security definer stable as $$
    select exists (select 1 from public.admins a where a.user_id = auth.uid());
  $$;
grant execute on function public.is_admin() to anon, authenticated;

-- ---------------- broadcasts ----------------
create table if not exists public.broadcasts (
  id         bigserial primary key,
  message    text not null check (char_length(message) between 1 and 240),
  kind       text not null default 'info',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 day'
);
alter table public.broadcasts enable row level security;

drop policy if exists "broadcasts are public" on public.broadcasts;
drop policy if exists "admins write broadcasts" on public.broadcasts;
drop policy if exists "admins edit broadcasts" on public.broadcasts;
drop policy if exists "admins delete broadcasts" on public.broadcasts;

create policy "broadcasts are public"    on public.broadcasts for select using (true);
create policy "admins write broadcasts"  on public.broadcasts for insert with check (public.is_admin());
create policy "admins edit broadcasts"   on public.broadcasts for update using (public.is_admin());
create policy "admins delete broadcasts" on public.broadcasts for delete using (public.is_admin());

-- ---------------- grants ----------------
-- An admin drops a reward here; the target's own game picks it up on its next
-- sync and applies it. Nobody ever writes to somebody else's save directly.
create table if not exists public.grants (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('coins','bike','xp','pass','trick')),
  amount     bigint not null default 0,
  note       text not null default '',
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
create index if not exists grants_user on public.grants (user_id) where claimed_at is null;
alter table public.grants enable row level security;

drop policy if exists "read own grants"    on public.grants;
drop policy if exists "admins send grants" on public.grants;
drop policy if exists "claim own grants"   on public.grants;
drop policy if exists "admins drop grants" on public.grants;

-- you can see grants addressed to you; admins can see everything they sent
create policy "read own grants"    on public.grants for select
  using (auth.uid() = user_id or public.is_admin());
create policy "admins send grants" on public.grants for insert with check (public.is_admin());
-- the target marks their own grant claimed
create policy "claim own grants"   on public.grants for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "admins drop grants" on public.grants for delete using (public.is_admin());

-- ---------------- make yourself an admin ----------------
-- Change the username below to yours, then run it. You must have signed in and
-- played at least once so a scores row exists to look you up by.
--
--   insert into public.admins (user_id)
--   select user_id from public.scores where lower(username) = lower('YOUR_USERNAME')
--   on conflict (user_id) do nothing;
