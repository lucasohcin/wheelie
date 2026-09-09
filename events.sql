-- SoFlo Wheelie Life - live events
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.is_admin() from admin.sql.
--
-- The game works without this table: no events ever start, the menu card and
-- the riding banner simply do not appear, and nothing else changes.

-- ============================================================
-- EVENTS
-- The answer to "admin abuse is boring". Handing one player a pile of coins is
-- invisible to everybody else and makes the game worse for them; starting an
-- hour of triple coins is visible to everyone at once and makes the game
-- better for all of them. So the interesting power an admin has is now this
-- one, and the boring power is capped (see admin.sql).
--
-- An event is a kind, a strength and an end time. Everybody polls the table on
-- the same 45 second beat the announcements already use and applies whatever
-- is live. Nothing is stored per player and nothing needs claiming.
--
-- Deliberately South Florida only. Afterburn's whole point is that its
-- currency is slow and earned; a 100x coin hour would flatten it in an
-- afternoon. The client refuses to apply any of this in the second world.
-- ============================================================
create table if not exists public.events (
  id         bigserial primary key,
  kind       text not null check (kind in ('coins','xp','rain','moon','turbo')),
  mult       numeric not null default 2 check (mult >= 1 and mult <= 100),
  note       text not null default '' check (char_length(note) <= 80),
  started_by uuid references auth.users(id) on delete set null,
  author     text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- an event is minutes-to-hours, never open ended. Somebody will start one
  -- and forget, and a permanent 100x is the same problem in slower motion.
  constraint events_window check (expires_at > created_at
                              and expires_at <= created_at + interval '6 hours')
);
create index if not exists events_live on public.events (expires_at desc);

alter table public.events enable row level security;

drop policy if exists "events are public"  on public.events;
drop policy if exists "admins start events" on public.events;
drop policy if exists "admins end events"   on public.events;

-- everyone needs to read them, including players who are not signed in
create policy "events are public"   on public.events for select using (true);
create policy "admins start events" on public.events for insert with check (public.is_admin());
create policy "admins end events"   on public.events for delete using (public.is_admin());

-- Who started it, stamped from the account rather than taken from the request,
-- for the same reason a profile username is: so nobody can run an event under
-- somebody else's name.
--
-- This also enforces one live event per kind. A unique partial index cannot do
-- it, because `now()` is not immutable and Postgres will not accept it in an
-- index predicate; a trigger can. Without the rule an admin could stack five
-- 100x coin events and the client would have to invent a meaning for that.
create or replace function public.events_guard() returns trigger
  language plpgsql security definer as $$
begin
  new.started_by = auth.uid();
  new.author = coalesce(
    (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = auth.uid()),
    '');
  if exists (select 1 from public.events e
              where e.kind = new.kind and e.expires_at > now()) then
    raise exception 'A % event is already running - end that one first', new.kind;
  end if;
  return new;
end $$;

drop trigger if exists events_authored on public.events;
create trigger events_authored before insert on public.events
  for each row execute function public.events_guard();
