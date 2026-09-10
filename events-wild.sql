-- SoFlo Wheelie Life - fifteen more events, and rebirths as a gift
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.events from events.sql and public.grants from admin.sql.
--
-- Its own file for the same reason admin-limits.sql was: events.sql has
-- already been run, so an edit buried in the middle of it is an edit nobody
-- runs. A new file is a thing you can see is new.
--
-- Until this is applied the game still works. The new events simply cannot be
-- started - the database refuses the kind - and the panel says so when you
-- try. Nothing that is already running is touched.

-- ---------------- the new event kinds ----------------
-- The five original events were multipliers with a small bit of weather on
-- top. These fifteen are meant to be SEEN: the point of an event is that
-- everybody riding at that moment knows something is happening, and a number
-- in the corner of the screen is not that.
--
-- The kind list is a column check constraint, so its name is generated. Find
-- it rather than guessing, or a re-run leaves the old one in place next to the
-- new one and every new kind is refused by whichever is stricter.
do $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
            where con.conrelid = 'public.events'::regclass and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ilike '%kind%'
  loop
    execute format('alter table public.events drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.events add constraint events_kind_check check (kind in (
  -- the originals
  'coins','xp','rain','moon','turbo',
  -- the sky
  'meteor','blood','thunder','eclipse','volcano','storm',
  -- the road
  'disco','rainbow','gold','jackpot','frost',
  -- the horizon
  'ufo','swarm','hyper','zero'
));

-- One live event per kind is still the rule, enforced by events_guard in
-- events.sql, and it needs no change: it compares new.kind against whatever is
-- running, so it covers the new kinds the moment they are allowed.

-- ---------------- rebirths as a gift ----------------
-- A rebirth is normally paid for: level 25, and it takes the garage, the
-- coins, the level and the pass with it. Handing one over is handing over the
-- multiplier without the price, which is exactly the sort of thing that should
-- not be inside an ordinary admin's daily budget - so it is super admin only,
-- alongside embers and the road to Afterburn.
--
-- The receiving game adds to the count and touches nothing else. It is a gift,
-- not a reset: nobody's garage is emptied by being given one.
do $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
            where con.conrelid = 'public.grants'::regclass and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ilike '%kind%'
  loop
    execute format('alter table public.grants drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.grants add constraint grants_kind_check
  check (kind in ('coins','bike','xp','pass','trick','embers','w2key','rebirth'));

-- grants_guard already refuses embers and w2key to anybody who is not super.
-- Rebirths join that list. Everything else in the function is untouched, and
-- the super admin door at the top of it still returns before any of it.
create or replace function public.grants_guard() returns trigger
  language plpgsql security definer as $$
declare
  coins_day   bigint;
  coins_to    bigint;
  xp_day      bigint;
  rows_day    bigint;
  lim_coin_one constant bigint := 100000;
  lim_coin_day constant bigint := 250000;
  lim_xp_one   constant bigint := 5000;
  lim_xp_day   constant bigint := 20000;
  lim_rows_day constant bigint := 20;
begin
  new.sent_by = auth.uid();
  new.sudo = public.is_super();

  if new.amount < 0 then
    raise exception 'Amount cannot be negative';
  end if;

  -- The super admin door. Below this line every rule is a rule about admins,
  -- and the owner of the game is not one of the people it protects it from.
  if new.sudo then
    return new;
  end if;

  if new.kind in ('embers','w2key','rebirth') then
    raise exception 'That one is the super admins to give, not an admins';
  end if;

  if new.user_id = auth.uid() then
    raise exception 'An admin cannot gift themselves';
  end if;

  -- Afterburn is off limits. 88 is W2_BIKE0 in the game; keep the two in step.
  if new.kind = 'bike' and new.amount >= 88 then
    raise exception 'Afterburn bikes are not an admins to give';
  end if;

  select count(*) into rows_day from public.grants g
    where g.sent_by = auth.uid() and g.created_at > now() - interval '24 hours';
  if rows_day >= lim_rows_day then
    raise exception 'Daily limit: % gifts in 24 hours', lim_rows_day;
  end if;

  if new.kind = 'coins' then
    if new.amount > lim_coin_one then
      raise exception 'The most you can gift at once is % coins', lim_coin_one;
    end if;
    select coalesce(sum(g.amount), 0) into coins_to from public.grants g
      where g.sent_by = auth.uid() and g.user_id = new.user_id
        and g.kind = 'coins' and g.created_at > now() - interval '24 hours';
    if coins_to + new.amount > lim_coin_one then
      raise exception 'That rider has already had % of their % coin daily limit from you',
        coins_to, lim_coin_one;
    end if;
    select coalesce(sum(g.amount), 0) into coins_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'coins'
        and g.created_at > now() - interval '24 hours';
    if coins_day + new.amount > lim_coin_day then
      raise exception 'You have given % of your % coins for today', coins_day, lim_coin_day;
    end if;
  end if;

  if new.kind = 'xp' then
    if new.amount > lim_xp_one then
      raise exception 'The most you can gift at once is % XP', lim_xp_one;
    end if;
    select coalesce(sum(g.amount), 0) into xp_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'xp'
        and g.created_at > now() - interval '24 hours';
    if xp_day + new.amount > lim_xp_day then
      raise exception 'You have given % of your % XP for today', xp_day, lim_xp_day;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists grants_guarded on public.grants;
create trigger grants_guarded before insert on public.grants
  for each row execute function public.grants_guard();
