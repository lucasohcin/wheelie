-- SoFlo Wheelie Life — daily seed run board
-- Run this in Supabase → SQL Editor. Safe to run more than once.
--
-- The game works without this table: the daily run still plays, still pays,
-- and still keeps your score on the device. Only the shared board needs it.

-- ============================================================
-- DAILY
-- One row per rider per day. `day` is the number the client derives from a
-- UTC clock, so every rider in the world is filing against the same integer.
--
-- The whole point of the mode is one attempt, and this table is where that
-- is actually enforced: the primary key allows exactly one row per rider per
-- day, and there is no update policy and no delete policy, so a row that
-- exists can never be improved. A client that decides to try again is
-- refused by the database rather than by the page.
-- ============================================================
create table if not exists public.daily (
  user_id    uuid    not null references auth.users(id) on delete cascade,
  day        integer not null check (day > 0 and day < 100000),
  username   text    not null,
  score      integer not null default 0 check (score >= 0 and score <= 10000000),
  dist       integer not null default 0 check (dist  >= 0 and dist  <= 1000000),
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);

alter table public.daily enable row level security;

drop policy if exists "daily board is public" on public.daily;
drop policy if exists "insert own daily"      on public.daily;

-- anyone signed in may read the board
create policy "daily board is public" on public.daily
  for select using (true);
-- you may only ever file your own run, once
create policy "insert own daily" on public.daily
  for insert with check (auth.uid() = user_id);

-- the board is always read as "today, best first"
create index if not exists daily_day_score on public.daily (day, score desc);

-- created_at is the server's, never the client's
create or replace function public.stamp_daily() returns trigger
  language plpgsql as $$
begin
  new.created_at = now();
  return new;
end $$;

drop trigger if exists daily_stamp on public.daily;
create trigger daily_stamp before insert on public.daily
  for each row execute function public.stamp_daily();
