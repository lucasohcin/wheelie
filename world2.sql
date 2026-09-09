-- SoFlo Wheelie Life - Afterburn (world 2) leaderboard
-- Run this in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.touch_save() from supabase-setup.sql.
--
-- The game works without this table: Afterburn plays and pays normally, your
-- own records still save, and the board tab says it is not set up yet rather
-- than dying. `scoresPush()` swallows the rejection so nothing else breaks.

-- ============================================================
-- SCORES2
-- Deliberately a second table rather than three more columns on `scores`.
-- The two worlds share no economy, no bikes and no maps, so a number from one
-- is meaningless next to a number from the other; keeping them apart means a
-- query for "the Afterburn board" cannot accidentally return South Florida
-- rows, and the monotonic trigger on each stays a two-line function.
-- Same shape, same policies, same "only ever goes up" rule as `scores`.
-- ============================================================
create table if not exists public.scores2 (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null,
  best       integer not null default 0 check (best       >= 0 and best       <= 100000000),
  best_ride  integer not null default 0 check (best_ride  >= 0 and best_ride  <= 100000000),
  ramp_best  integer not null default 0 check (ramp_best  >= 0 and ramp_best  <= 100000000),
  updated_at timestamptz not null default now()
);

alter table public.scores2 enable row level security;

drop policy if exists "afterburn board is public" on public.scores2;
drop policy if exists "insert own afterburn score" on public.scores2;
drop policy if exists "update own afterburn score" on public.scores2;

-- anyone signed in may read the board
create policy "afterburn board is public" on public.scores2
  for select using (true);
-- but you may only ever write your own row
create policy "insert own afterburn score" on public.scores2
  for insert with check (auth.uid() = user_id);
create policy "update own afterburn score" on public.scores2
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop trigger if exists scores2_touch on public.scores2;
create trigger scores2_touch before insert or update on public.scores2
  for each row execute function public.touch_save();

create index if not exists scores2_best      on public.scores2 (best      desc);
create index if not exists scores2_best_ride on public.scores2 (best_ride desc);
create index if not exists scores2_ramp_best on public.scores2 (ramp_best desc);

-- Scores may only ever go up. Without this a stale device could sync an old,
-- lower score over a newer record - and a rider who switched worlds and back
-- syncs both tables every time, so stale writes here are routine, not rare.
create or replace function public.scores2_monotonic() returns trigger
  language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    new.best      = greatest(new.best,      old.best);
    new.best_ride = greatest(new.best_ride, old.best_ride);
    new.ramp_best = greatest(new.ramp_best, old.ramp_best);
  end if;
  return new;
end $$;

drop trigger if exists scores2_only_up on public.scores2;
create trigger scores2_only_up before update on public.scores2
  for each row execute function public.scores2_monotonic();
