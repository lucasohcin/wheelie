-- SoFlo Wheelie Life - leaderboard table
-- Run this in Supabase > SQL Editor. Safe to run more than once.
-- (Already included at the end of supabase-setup.sql; this is just the new part.)

-- ============================================================
-- LEADERBOARD
-- A deliberately separate, deliberately thin table. `saves` stays private;
-- this one is world readable but holds nothing except a name and scores.
-- ============================================================
create table if not exists public.scores (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  username   text not null,
  best       integer not null default 0 check (best       >= 0 and best       <= 100000000),
  best_ride  integer not null default 0 check (best_ride  >= 0 and best_ride  <= 100000000),
  ramp_best  integer not null default 0 check (ramp_best  >= 0 and ramp_best  <= 100000000),
  updated_at timestamptz not null default now()
);

alter table public.scores enable row level security;

drop policy if exists "leaderboard is public"   on public.scores;
drop policy if exists "insert own score"        on public.scores;
drop policy if exists "update own score"        on public.scores;

-- anyone may read the board
create policy "leaderboard is public" on public.scores
  for select using (true);
-- but you may only ever write your own row
create policy "insert own score" on public.scores
  for insert with check (auth.uid() = user_id);
create policy "update own score" on public.scores
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop trigger if exists scores_touch on public.scores;
create trigger scores_touch before insert or update on public.scores
  for each row execute function public.touch_save();

create index if not exists scores_best      on public.scores (best      desc);
create index if not exists scores_best_ride on public.scores (best_ride desc);
create index if not exists scores_ramp_best on public.scores (ramp_best desc);

-- Scores may only ever go up. Without this a stale device could sync an old,
-- lower score over a newer record.
create or replace function public.scores_monotonic() returns trigger
  language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    new.best      = greatest(new.best,      old.best);
    new.best_ride = greatest(new.best_ride, old.best_ride);
    new.ramp_best = greatest(new.ramp_best, old.ramp_best);
  end if;
  return new;
end $$;

drop trigger if exists scores_only_up on public.scores;
create trigger scores_only_up before update on public.scores
  for each row execute function public.scores_monotonic();
