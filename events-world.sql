-- SoFlo Wheelie Life - events that change the world itself
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.events from events.sql.
--
-- Its own file for the reason events-wild.sql was its own file: events.sql and
-- events-wild.sql have both already been run, so an edit buried in the middle
-- of either is an edit nobody runs. A new file is a thing you can see is new.
--
-- Until this is applied the game still works. The ten new events simply cannot
-- be started - the database refuses the kind, and the admin panel says so when
-- you try. Nothing already running is touched, and the twenty that were there
-- before carry on exactly as they were.
--
-- ============================================================
-- WHAT IS NEW
-- ------------------------------------------------------------
-- The twenty events that existed changed what the world DID to you: more
-- coins, less gravity, a harder wind, things falling out of the sky. These ten
-- change what the world IS.
--
-- Six of them reshape the ground. While one is running, the ramp generator
-- hands over to it, so the track becomes something else a few hundred metres
-- ahead of the rider and turns back when the event ends - nothing already
-- generated is disturbed:
--
--   canyon     every jump is over a chasm
--   stairway   the floor drops away a step at a time
--   megaramp   one enormous kicker after another
--   washboard  whoops as far as you can see
--   spires     towers with nothing between them
--   glass      dead flat, dead fast, and style banks at a multiplier
--
-- Four repaint the map. The dirt, the grass, the hills, the sky and the water
-- are all swapped together, so the ramp world becomes a different place, and a
-- matching wash carries the same mood onto the street:
--
--   night      the sun goes down on both worlds
--   neon       the strip goes electric
--   wildfire   the hills burn
--   tide       the water comes up
--
-- NONE of it reaches the daily or the trial. Those are one seeded track that
-- every rider in the world is supposed to be riding at the same time, and an
-- event that reshaped them would quietly put two people on different courses
-- while they compared scores on the same board. A repaint is no safer than a
-- reshape there, because the palette carries `water` and `tree` and the
-- generator reads both - so the look would change the shape with it. The
-- client refuses both on a seeded run, and refuses everything in Afterburn as
-- it already did.
-- ============================================================

-- The kind list is a column check constraint, so its name is generated unless
-- events-wild.sql named it. Find whatever is there rather than guessing: a
-- re-run that leaves the old constraint beside the new one means the stricter
-- of the two wins, and every new kind is refused by a rule you cannot see.
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
  -- the five originals
  'coins','xp','rain','moon','turbo',
  -- the sky
  'meteor','blood','thunder','eclipse','volcano','storm',
  -- the road
  'disco','rainbow','gold','jackpot','frost',
  -- the horizon
  'ufo','swarm','hyper','zero',
  -- the ground itself
  'canyon','stairway','megaramp','washboard','spires','glass',
  -- the map
  'night','neon','wildfire','tide'
));

-- One live event per kind is still the rule and still enforced by events_guard
-- in events.sql, which compares new.kind against whatever is running - so it
-- covers these the moment they are allowed. Two DIFFERENT terrain events at
-- once is possible and deliberately left alone: the client picks the first one
-- it finds rather than trying to combine them, which is the same answer
-- evtBest gives when two multipliers overlap.
