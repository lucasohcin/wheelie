-- SoFlo Wheelie Life — time trial board
-- Run this in Supabase → SQL Editor. Safe to run more than once.
--
-- The game works without this table: the trial still runs and your own best
-- still saves. Only the shared board needs it.

-- ============================================================
-- TRIALS
-- One row per rider per week, because the course is seeded off the week and
-- everybody rides the same one until it rolls over.
--
-- This is the one board in the game where the smallest number wins, so the
-- trigger keeps the LEAST of the two rather than the greatest. Without it a
-- stale device could sync a slower run over a faster one, which is the same
-- bug the score table's monotonic trigger exists to prevent, upside down.
-- ============================================================
create table if not exists public.trials (
  user_id    uuid    not null references auth.users(id) on delete cascade,
  week       integer not null check (week > 0 and week < 100000),
  username   text    not null,
  ms         integer not null check (ms > 0 and ms <= 3600000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, week)
);

alter table public.trials enable row level security;

drop policy if exists "trial board is public" on public.trials;
drop policy if exists "insert own trial"      on public.trials;
drop policy if exists "update own trial"      on public.trials;

-- anyone signed in may read the board
create policy "trial board is public" on public.trials
  for select using (true);
-- but you may only ever write your own row
create policy "insert own trial" on public.trials
  for insert with check (auth.uid() = user_id);
create policy "update own trial" on public.trials
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- the board is always read as "this week, fastest first"
create index if not exists trials_week_ms on public.trials (week, ms asc);

-- a time may only ever come down
create or replace function public.trials_only_faster() returns trigger
  language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    new.ms = least(new.ms, old.ms);
  end if;
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trials_faster on public.trials;
create trigger trials_faster before insert or update on public.trials
  for each row execute function public.trials_only_faster();
