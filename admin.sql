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

-- ---------------- limits on what an admin may give ----------------
-- These live here and not in the panel on purpose. The passphrase is only a
-- door; anyone who reads the page source can call the REST endpoint directly,
-- so a cap written in JavaScript is decoration. Every rule below is enforced
-- by the database against auth.uid() and cannot be talked out of.
--
-- The rules, and why:
--   * no gifting yourself - the single most abusable thing an admin can do
--   * 100,000 coins is the most anyone may receive from one admin in a day,
--     however many separate grants it is split across
--   * 250,000 coins a day is the most one admin may hand out in total
--   * XP is capped the same way, and the number of grants a day is capped so
--     passes and tricks cannot be sprayed around instead
--   * nothing from Afterburn. Bike indexes 88 and up are the second world and
--     are not an admin's to give: that economy is meant to be earned.
alter table public.grants add column if not exists sent_by uuid references auth.users(id) on delete set null;
create index if not exists grants_sent_by_day on public.grants (sent_by, created_at desc);

create or replace function public.grants_guard() returns trigger
  language plpgsql security definer as $$
declare
  coins_day   bigint;
  coins_to    bigint;
  xp_day      bigint;
  rows_day    bigint;
  COIN_ONE constant bigint := 100000;   -- per recipient, per day
  COIN_DAY constant bigint := 250000;   -- per admin, per day, everyone
  XP_ONE   constant bigint := 5000;
  XP_DAY   constant bigint := 20000;
  ROWS_DAY constant bigint := 20;
begin
  -- the sender is who the request is from, never what the request claims
  new.sent_by = auth.uid();

  if new.user_id = auth.uid() then
    raise exception 'An admin cannot gift themselves';
  end if;

  if new.amount < 0 then
    raise exception 'Amount cannot be negative';
  end if;

  -- Afterburn is off limits. 88 is W2_BIKE0 in the game; keep the two in step.
  if new.kind = 'bike' and new.amount >= 88 then
    raise exception 'Afterburn bikes are not an admins to give';
  end if;

  select count(*) into rows_day from public.grants g
    where g.sent_by = auth.uid() and g.created_at > now() - interval '24 hours';
  if rows_day >= ROWS_DAY then
    raise exception 'Daily limit: % gifts in 24 hours', ROWS_DAY;
  end if;

  if new.kind = 'coins' then
    if new.amount > COIN_ONE then
      raise exception 'The most you can gift at once is % coins', COIN_ONE;
    end if;
    select coalesce(sum(g.amount), 0) into coins_to from public.grants g
      where g.sent_by = auth.uid() and g.user_id = new.user_id
        and g.kind = 'coins' and g.created_at > now() - interval '24 hours';
    if coins_to + new.amount > COIN_ONE then
      raise exception 'That rider has already had % of their % coin daily limit from you',
        coins_to, COIN_ONE;
    end if;
    select coalesce(sum(g.amount), 0) into coins_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'coins'
        and g.created_at > now() - interval '24 hours';
    if coins_day + new.amount > COIN_DAY then
      raise exception 'You have given % of your % coins for today', coins_day, COIN_DAY;
    end if;
  end if;

  if new.kind = 'xp' then
    if new.amount > XP_ONE then
      raise exception 'The most you can gift at once is % XP', XP_ONE;
    end if;
    select coalesce(sum(g.amount), 0) into xp_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'xp'
        and g.created_at > now() - interval '24 hours';
    if xp_day + new.amount > XP_DAY then
      raise exception 'You have given % of your % XP for today', xp_day, XP_DAY;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists grants_guarded on public.grants;
create trigger grants_guarded before insert on public.grants
  for each row execute function public.grants_guard();

-- What an admin has spent today, so the panel can show it before they type a
-- number rather than after the database refuses it. security definer because
-- it sums rows the caller is not otherwise entitled to read in aggregate.
create or replace function public.grant_budget()
  returns table (coins_day bigint, xp_day bigint, rows_day bigint)
  language sql security definer stable as $$
    select coalesce(sum(g.amount) filter (where g.kind = 'coins'), 0)::bigint,
           coalesce(sum(g.amount) filter (where g.kind = 'xp'), 0)::bigint,
           count(*)::bigint
      from public.grants g
     where g.sent_by = auth.uid() and g.created_at > now() - interval '24 hours';
  $$;
grant execute on function public.grant_budget() to authenticated;

-- ---------------- who said it ----------------
-- An announcement used to arrive signed "ANNOUNCEMENT", which made admin abuse
-- anonymous. The name is stamped from the account, never taken from the
-- request, for the same reason a profile username is.
alter table public.broadcasts add column if not exists sent_by uuid references auth.users(id) on delete set null;
alter table public.broadcasts add column if not exists author  text not null default '';

create or replace function public.stamp_author() returns trigger
  language plpgsql security definer as $$
begin
  new.sent_by = auth.uid();
  new.author = coalesce(
    (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = auth.uid()),
    '');
  return new;
end $$;

drop trigger if exists broadcasts_author on public.broadcasts;
create trigger broadcasts_author before insert or update on public.broadcasts
  for each row execute function public.stamp_author();

-- ---------------- make yourself an admin ----------------
-- Change the username below to yours, then run it. You must have signed in and
-- played at least once so a scores row exists to look you up by.
--
--   insert into public.admins (user_id)
--   select user_id from public.scores where lower(username) = lower('YOUR_USERNAME')
--   on conflict (user_id) do nothing;
