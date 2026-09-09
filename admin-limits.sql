-- SoFlo Wheelie Life - admin gift limits, and who said it
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.admins / public.grants / public.broadcasts from admin.sql.
--
-- Split out of admin.sql rather than left in it: admin.sql had already been
-- run once, so an edit buried in the middle of it is an edit nobody runs. Its
-- own file is a thing you can see is new.
--
-- Until this is applied there are no caps at all. The game says so, in red, at
-- the bottom of the admin panel's gift card.

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
