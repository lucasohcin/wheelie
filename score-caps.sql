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
--
-- ------------------------------------------------------------
-- WHY THE FIRST VERSION OF THIS FILE NEVER APPLIED
-- ------------------------------------------------------------
-- It went straight to `alter table public.scores alter column best type
-- bigint`, and Postgres refused:
--
--   ERROR: 0A000: cannot alter type of a column used by a view or rule
--   DETAIL: rule _RETURN on view crew_board depends on column "best"
--
-- crews.sql builds public.crew_board on top of scores.best, best_ride and
-- ramp_best to add a crew's scores together. A view pins the TYPE of every
-- column it reads, and Postgres will not retype a column out from under one -
-- there is no `alter ... cascade` for this.
--
-- The Supabase SQL editor runs a script as one transaction, so the failure
-- rolled the whole file back: the constraints were not dropped, the columns
-- were not widened, and the board carried on refusing anything over a hundred
-- million exactly as before. The file reported an error, but an error at the
-- top of a long script is easy to read as "already done" - and every symptom
-- afterwards was identical to the bug never having been fixed.
--
-- So the view is dropped before the columns are retyped and rebuilt after,
-- from the same definition crews.sql uses. And because a second view added
-- later would reproduce this exact stall, the file now looks for dependents
-- FIRST and names any it does not know how to rebuild, rather than letting
-- Postgres fail halfway through with a message about a rule called _RETURN.
-- ============================================================

-- ---------------- anything reading these columns ----------------
-- Views pin column types. Find every one that reads a score column, and stop
-- with a sentence naming it unless it is crew_board, which this file knows how
-- to put back. Better a refusal that says what to do than a rollback that
-- looks like success to anybody not reading the output.
do $$
declare v text; extra text[] := '{}';
begin
  for v in
    select distinct c.relname
      from pg_depend d
      join pg_rewrite r on r.oid = d.objid and r.rulename = '_RETURN'
      join pg_class   c on c.oid = r.ev_class
      join pg_class   t on t.oid = d.refobjid
     where c.relkind in ('v', 'm')
       and t.relname in ('scores', 'scores2', 'daily')
       and t.relnamespace = 'public'::regnamespace
       and c.relname <> 'crew_board'
  loop
    extra := extra || v;
  end loop;
  if array_length(extra, 1) > 0 then
    raise exception
      'These views read the score columns and will block the retype: %. '
      'Drop them, run this file, then create them again.', array_to_string(extra, ', ');
  end if;
end $$;

-- crew_board is rebuilt at the bottom of this file, verbatim from crews.sql.
drop view if exists public.crew_board;

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

-- ---------------- put crew_board back ----------------
-- Verbatim from crews.sql, including the grant, which a DROP takes with it.
-- Keep the two in step: if the view changes there, change it here too.
--
-- The sums need no widening. `sum(bigint)` returns numeric in Postgres and the
-- ::bigint cast is applied to the sum rather than to each term, so a crew's
-- combined total is right until it passes nine quintillion. What DID need
-- fixing is that the view existed at all when the retype ran.
--
-- Skipped without complaint if crews.sql has not been run - there is nothing
-- to rebuild, and creating a view over tables that do not exist would fail the
-- file for a feature this database is not using.
do $$
begin
  if to_regclass('public.crews') is null or to_regclass('public.crew_members') is null then
    raise notice 'public.crews not found - skipping crew_board (run crews.sql if you want crews)';
    return;
  end if;
  execute $v$
    create or replace view public.crew_board as
      select c.id,
             c.name,
             c.tag,
             count(m.user_id)                       as members,
             coalesce(sum(s.best), 0)::bigint       as total_best,
             coalesce(max(s.best), 0)::bigint       as top_best,
             coalesce(sum(s.best_ride), 0)::bigint  as total_ride,
             coalesce(sum(s.ramp_best), 0)::bigint  as total_ramp
        from public.crews c
        left join public.crew_members m on m.crew_id = c.id
        left join public.scores s       on s.user_id = m.user_id
       group by c.id, c.name, c.tag
  $v$;
  execute 'grant select on public.crew_board to anon, authenticated';
end $$;

-- ---------------- check it worked ----------------
-- This used to be a commented-out suggestion, which meant running the file
-- printed "Success. No rows returned" and told you nothing - and a board that
-- is still broken afterwards looks exactly like a board that was never fixed.
-- It is a real query now. Read the output before you close the tab.
--
-- WANT: every row says bigint, and every ceiling reads 9000000000000000.
-- Any row still saying `integer`, or a ceiling of 100000000, means that table
-- did not get migrated - usually because it did not exist yet when this file
-- was last run. Run the file that creates it, then run this one again.
--
-- If you get output at all, the file reached the end and the retype worked -
-- the failure this file was written to survive stops it long before here.
select t.table_name,
       c.column_name,
       c.data_type,
       case when c.data_type = 'bigint' then 'ok' else 'STILL CAPPED - re-run this file' end as verdict
  from information_schema.columns c
  join (values ('scores'),('scores2'),('daily')) as t(table_name)
    on t.table_name = c.table_name
 where c.table_schema = 'public'
   and c.column_name in ('best','best_ride','ramp_best','score','dist')
 order by t.table_name, c.column_name;

-- And the ceilings themselves, straight out of the constraint definitions.
select con.conrelid::regclass as table_name,
       con.conname,
       pg_get_constraintdef(con.oid) as rule
  from pg_constraint con
 where con.contype = 'c'
   and con.conrelid in (
     select oid from pg_class
      where relname in ('scores','scores2','daily') and relnamespace = 'public'::regnamespace)
 order by 1, 2;
