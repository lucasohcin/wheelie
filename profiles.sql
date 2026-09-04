-- SoFlo Wheelie Life — rider profiles
-- Run this in Supabase → SQL Editor. Safe to run more than once.
-- Depends on public.is_admin() from admin.sql.
--
-- The game works without this table: profiles simply say they are not set up
-- yet. Nothing else in the game reads it.

-- ============================================================
-- PROFILES
-- A public card for each rider: what they ride, what they call themselves,
-- and a line about who they are. Deliberately thin, and deliberately its own
-- table — `saves` stays private and nothing here is anything a player did not
-- choose to show.
--
-- `username` is never trusted from the client. Profiles are looked up by
-- username, so letting a client set it would let one player claim another's
-- name before they ever signed in. The trigger below overwrites it with the
-- name on the account every time the row is written.
-- ============================================================
create table if not exists public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  username     text not null default '',
  display_name text not null default '' check (char_length(display_name) <= 24),
  bio          text not null default '' check (char_length(bio)          <= 200),
  bike         integer not null default 0 check (bike   >= 0 and bike   < 500),
  lid          integer not null default 0 check (lid    >= 0 and lid    < 100),
  spot         integer not null default 0 check (spot   >= 0 and spot   < 100),
  level        integer not null default 1 check (level  >= 1 and level  <= 999),
  streak       integer not null default 0 check (streak >= 0 and streak <= 100000),
  paint        jsonb   not null default '{}'::jsonb
                 check (char_length(paint::text) <= 400),
  badges       text[]  not null default '{}'::text[],
  badge_count  integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Badges came later than the rest of the card. These two are safe to run on a
-- table that already exists, and the game copes with a database that has not
-- had them yet by filing everything except the badges.
alter table public.profiles add column if not exists badges      text[]  not null default '{}'::text[];
alter table public.profiles add column if not exists badge_count integer not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_badges_ok') then
    alter table public.profiles add constraint profiles_badges_ok
      check (coalesce(array_length(badges, 1), 0) <= 3
         and length(array_to_string(badges, ',')) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_badge_count_ok') then
    alter table public.profiles add constraint profiles_badge_count_ok
      check (badge_count >= 0 and badge_count <= 9999);
  end if;
end $$;

-- profiles are opened by name, so names must be unique and findable
create unique index if not exists profiles_username_lower on public.profiles (lower(username));

alter table public.profiles enable row level security;

drop policy if exists "profiles are public" on public.profiles;
drop policy if exists "insert own profile"  on public.profiles;
drop policy if exists "update own profile"  on public.profiles;
drop policy if exists "delete own profile"  on public.profiles;

-- anyone signed in may read a profile
create policy "profiles are public" on public.profiles
  for select using (true);
-- you may only ever write your own row - except that an admin may edit any
-- row, which is how a bio that should not be there gets cleared
create policy "insert own profile" on public.profiles
  for insert with check (auth.uid() = user_id);
create policy "update own profile" on public.profiles
  for update using      (auth.uid() = user_id or public.is_admin())
          with check    (auth.uid() = user_id or public.is_admin());
create policy "delete own profile" on public.profiles
  for delete using      (auth.uid() = user_id or public.is_admin());

-- The username on a profile comes off the account, never off the request.
-- security definer so it can read auth.users regardless of the caller.
create or replace function public.stamp_profile() returns trigger
  language plpgsql security definer as $$
begin
  new.username = coalesce(
    (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = new.user_id),
    new.username, '');
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists profiles_stamp on public.profiles;
create trigger profiles_stamp before insert or update on public.profiles
  for each row execute function public.stamp_profile();
