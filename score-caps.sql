-- SoFlo Wheelie Life - raise the score ceiling
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.scores from leaderboard.sql. Touches public.scores2 and
-- public.daily too, if those files have been run.
--
-- ============================================================
-- THE BUG THIS FIXES
-- ------------------------------------------------------------
-- `scores` was created with `check (best <= 100000000)` on all three columns,
-- and a hundred million is a number this game reaches. Rebirth multiplies
-- coins and score, Coin Rush multiplies them again, and the chain events hold
-- a combo open for minutes at a time - so riders started crossing it.
--
-- A CHECK is a row-level rule, not a column-level one. The moment ANY of the
-- three numbers went over the line the whole upsert was refused, and because
-- all three live in one row, one huge Street score stopped Ride Out and Ramp
-- saving as well. `scoresPush()` is called inside a `try {} catch(e){}` in
-- cloudSyncNow, so the rejection was swallowed: the rider saw no error at all,
-- just a board that quietly stopped moving. Everything above 100,000,000 was
-- lost.
--
-- Three things change here:
--   1. integer -> bigint. `integer` tops out at 2,147,483,647, which is only
--      21x further on and would have become the same bug again in a year.
--   2. The ceiling goes to 9,000,000,000,000,000 - under 2^53, so it still
--      survives the round trip through a JavaScript number without losing
--      precision. A cap is still worth having: it is what stops a tampered
--      client parking `Infinity` at the top of the board forever, and the
--      monotonic trigger means anything that lands there can never come down.
--   3. The client clamps to the same number before it sends, so a score that
--      somehow exceeds even this is filed at the ceiling rather than thrown
--      away along with the other two boards in the row.
-- ============================================================

-- ---------------- scores ----------------
-- The constraints are unnamed in leaderboard.sql, so Postgres generated their
-- names. Find them rather than guessing: a wrong guess leaves the old rule in
-- place beside the new one, and the stricter of the two is the one that wins,
-- which would look exactly like this fix not working.
do $$
declare c record;
begin
  for c in select con.conname, con.conrelid::regclass as tbl
             from pg_constraint con
            where con.conrelid in ('public.scores'::regclass, 'public.scores2'::regclass)
              and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ~* '(best|best_ride|ramp_best)'
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
exception
  -- scores2 only exists once world2.sql has been run. Fall back to scores
  -- alone rather than failing the whole file for a table that is optional.
  when undefined_table then
    for c in select con.conname from pg_constraint con
              where con.conrelid = 'public.scores'::regclass and con.contype = 'c'
                and pg_get_constraintdef(con.oid) ~* '(best|best_ride|ramp_best)'
    loop
      execute format('alter table public.scores drop constraint %I', c.conname);
    end loop;
end $$;

alter table public.scores
  alter column best      type bigint,
  alter column best_ride type bigint,
  alter column ramp_best type bigint;

alter table public.scores add constraint scores_range check (
  best      >= 0 and best      <= 9000000000000000 and
  best_ride >= 0 and best_ride <= 9000000000000000 and
  ramp_best >= 0 and ramp_best <= 9000000000000000
);

-- ---------------- scores2 ----------------
-- Afterburn's board, same shape and the same ceiling. Skipped without
-- complaint if world2.sql has not been run.
do $$
begin
  alter table public.scores2
    alter column best      type bigint,
    alter column best_ride type bigint,
    alter column ramp_best type bigint;

  alter table public.scores2 add constraint scores2_range check (
    best      >= 0 and best      <= 9000000000000000 and
    best_ride >= 0 and best_ride <= 9000000000000000 and
    ramp_best >= 0 and ramp_best <= 9000000000000000
  );
exception
  when undefined_table then
    raise notice 'public.scores2 does not exist yet - run world2.sql if you want the Afterburn board';
end $$;

-- ---------------- daily ----------------
-- The daily board had the same bug one decimal place lower: score capped at
-- 10,000,000 and dist at 1,000,000. The daily is insert-only, one row per
-- rider per day, so a refused insert did not block anything else - it just
-- meant the best run of the day was the one run that never appeared.
do $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
            where con.conrelid = 'public.daily'::regclass and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ~* '(score|dist)'
  loop
    execute format('alter table public.daily drop constraint %I', c.conname);
  end loop;

  alter table public.daily
    alter column score type bigint,
    alter column dist  type bigint;

  alter table public.daily add constraint daily_range check (
    score >= 0 and score <= 9000000000000000 and
    dist  >= 0 and dist  <= 9000000000000000
  );
exception
  when undefined_table then
    raise notice 'public.daily does not exist yet - run daily.sql if you want the daily board';
end $$;

-- ---------------- the crew totals ----------------
-- crew_board sums public.scores.best across a crew. It already casts to
-- bigint, so summing bigints needs no change there - but a sum of many large
-- bests can outrun bigint where one best could not, and numeric is what
-- Postgres promotes sum(bigint) to anyway. Left alone deliberately: the cast
-- in crews.sql is applied to the sum, not to each term, and `sum(bigint)`
-- returns numeric, so the existing `::bigint` is doing the right thing until a
-- crew's combined total passes nine quintillion.

-- ---------------- check it worked ----------------
-- Should list three bigint columns and one check constraint per table.
--   select column_name, data_type from information_schema.columns
--    where table_name = 'scores' and column_name in ('best','best_ride','ramp_best');
