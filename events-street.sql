-- SoFlo Wheelie Life - twenty-five events for the street and the ride out
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.events from events.sql.
--
-- Its own file for the reason events-wild.sql and events-world.sql were their
-- own files: the three before it have already been run, so an edit buried in
-- the middle of any of them is an edit nobody runs. A new file is a thing you
-- can see is new.
--
-- Until this is applied the game still works. The twenty-five new events
-- simply cannot be started - the database refuses the kind, and the admin
-- panel says so when you try. Nothing already running is touched, and the
-- thirty that were there before carry on exactly as they were.
--
-- ============================================================
-- WHY THESE, AND WHY HERE
-- ------------------------------------------------------------
-- The thirty events that existed were, almost all of them, events about the
-- RAMP world or about the sky above both worlds. The street - the mode most
-- people actually ride, and the only mode a ride out happens in - got a coin
-- multiplier, some weather, and nothing else. The whole spectacle layer was
-- built for a mode with two things in it.
--
-- These twenty-five are the street's. They come in three wings.
--
--   The games. Other people's games, played on a motorbike, because the ask
--   was for the kind of admin abuse that shows up in a Roblox front page:
--
--     garden     the asphalt splits open and grows things worth harvesting
--     brainrot   things sitting on the median, worth more taken in a row
--     fruit      one falls out of the sky and changes the rest of your run
--     pets       something rides with you and hoovers up whatever you pass
--     rush       something is behind you. Stay above 30
--     blade      it gets thrown at you. Brake the moment it arrives
--     jail       every cop in Broward is behind you. Stay above 34
--     nights     the sun does not come back up. Keep finding fires
--     fisch      the strip floods and they come up with it
--     chaos      a different disaster every twenty seconds
--
--   The insane. The wing that exists because somebody asked for the most
--   unhinged thing the street could survive:
--
--     tsunami    the ocean comes up the strip behind you
--     kaiju      something enormous walks the horizon and shakes coins loose
--     blackhole  a hole opens over the A1A and bends what is falling to you
--     giant      the rider is drawn twice the size
--     tiny       the rider is drawn at a third
--     bullet     the whole street runs at half speed
--     clones     three more of you, a beat behind, riding your own line
--     nuke       sirens, a light on the horizon, and everything at once
--     roll       the whole street turns over, and comes back around
--     hundred    coins, XP and style all multiplied together
--
--   The road. Ride out only, and every one of their cards says so - a ride
--   out is the only mode with traffic, a pack and potholes in it:
--
--     traffic    four times the cars, and every one you slip past pays
--     broken     three times the holes, five times the payout
--     ghost      not a car, not a rider, not a hole
--     rally      the whole county turns out, and passing feeds the chain
--     nitro      every bike on the strip runs past the limiter
--
-- Three of them can END a run on their own, which nothing else in this table
-- has ever been able to do: rush, jail and tsunami catch you if you slow
-- down, and blade takes the run if you do not brake. The client fences all
-- four the same way - never in versus, never while you are already down, and
-- the distance is handed back in full on a respawn so being caught is never
-- being caught twice. Worth knowing before you start one for four hours.
--
-- None of it reaches Afterburn, for the reason none of the other fifty do:
-- that economy is meant to be slow and earned, and the client returns nothing
-- from evtOn in the second world. None of it reaches the daily or the trial
-- either, because both of those are ramp runs and every one of these is a
-- street event - they simply never come up.
-- ============================================================

-- The kind list is a column check constraint. events-wild.sql named it
-- events_kind_check and events-world.sql kept that name, but find whatever is
-- actually there rather than trusting it: a re-run that leaves an old
-- constraint beside a new one means the stricter of the two wins, and every
-- new kind is refused by a rule you cannot see in the table definition.
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
  -- the road surface
  'disco','rainbow','gold','jackpot','frost',
  -- the horizon
  'ufo','swarm','hyper','zero',
  -- the ground itself
  'canyon','stairway','megaramp','washboard','spires','glass',
  -- the map
  'night','neon','wildfire','tide',
  -- the games
  'garden','brainrot','fruit','pets','rush','blade','jail','nights','fisch','chaos',
  -- the insane
  'tsunami','kaiju','blackhole','giant','tiny','bullet','clones','nuke','roll','hundred',
  -- the road
  'traffic','broken','ghost','rally','nitro'
));

-- One live event per kind is still the rule and still enforced by events_guard
-- in events.sql, which compares new.kind against whatever is running - so it
-- covers these the moment they are allowed. Two DIFFERENT street events at
-- once is possible and deliberately left alone; where two of them pull on the
-- same lever the client takes the best of them rather than the product, the
-- same answer evtBest has always given, and where two of them want the same
-- piece of the screen the first one found wins.
--
-- The strength number still tops out at 100, from the `mult` check on the
-- table itself. A 100x Hundredfold is coins, XP and style at a hundred times
-- each, which is the most extreme thing this table can express - it is meant
-- to be, and it is still an hour long at most, and it still cannot touch
-- Afterburn. That is the whole shape of the bargain: the loudest possible
-- thing, for everybody at once, in the world that can absorb it.
