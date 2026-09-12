-- SoFlo Wheelie Life - names you can trust
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.scores (leaderboard.sql). Everything else it touches is
-- optional and skipped with a notice if that file has not been run.
--
-- ============================================================
-- THE HOLE THIS CLOSES
-- ------------------------------------------------------------
-- profiles.sql states the rule and explains it well:
--
--   "`username` is never trusted from the client. Profiles are looked up by
--    username, so letting a client set it would let one player claim
--    another's name before they ever signed in."
--
-- That rule was written for `profiles` and applied only to `profiles`. Five
-- other tables store a username, all of them take it straight off the request,
-- and every row level policy on them checks the `user_id` and stops there:
--
--   public.scores        the leaderboard
--   public.scores2       the Afterburn leaderboard
--   public.daily         the daily seed board
--   public.trials        the weekly time trial board
--   public.crew_members  the crew roster
--
-- So the name beside a score has never been checked against the account that
-- filed it. Anybody willing to POST at the API directly - and the anon key is
-- printed in the page source, because that is what an anon key is for - could
-- put any name they liked on their own row. That is impersonation on the most
-- public surface the game has.
--
-- It is worse than cosmetic, because two admin tools resolve a person BY that
-- name. `findRider()` in the admin panel looks a gift target up in
-- public.scores, and `super_find()` falls back to the same table when an
-- account predates usernames being kept in the signup metadata. A row claiming
-- to be somebody else could therefore catch gifts meant for them.
--
-- One trigger function, five tables. It stamps the name from the account on
-- insert and on update both - stamping only on insert would let the name be
-- changed a moment after it was filed honestly.
-- ============================================================

-- auth.users is the authority. public.scores is the fallback for an account
-- that predates usernames being kept in the signup metadata, which is the same
-- fallback super_find() already uses - and for a row ON public.scores it reads
-- the row being replaced rather than itself, so an established name survives
-- rather than being blanked.
create or replace function public.stamp_username() returns trigger
  language plpgsql security definer
  set search_path = public, pg_temp as $$
declare who text;
begin
  if new.user_id is null then
    new.user_id := auth.uid();
  end if;
  if new.user_id is null then
    raise exception 'Sign in first';
  end if;
  select u.raw_user_meta_data ->> 'username' into who
    from auth.users u where u.id = new.user_id;
  if coalesce(btrim(who), '') = '' then
    select s.username into who from public.scores s where s.user_id = new.user_id;
  end if;
  new.username := coalesce(nullif(btrim(who), ''), nullif(btrim(new.username), ''), 'rider');
  return new;
end $$;

-- Attached to whichever of the five actually exist. A missing table is a file
-- that has not been run, not a failure.
do $$
declare t text;
begin
  foreach t in array array['scores','scores2','daily','trials','crew_members']
  loop
    if to_regclass('public.' || t) is null then
      raise notice 'public.% does not exist yet - skipped', t;
      continue;
    end if;
    execute format('drop trigger if exists %I on public.%I', t || '_named', t);
    execute format(
      'create trigger %I before insert or update on public.%I
         for each row execute function public.stamp_username()',
      t || '_named', t);
  end loop;
end $$;

-- ---------------- the names already filed ----------------
-- Anything that was never true, put right. Safe to re-run; does nothing once
-- the triggers above have been in place for a while.
do $$
declare t text;
begin
  foreach t in array array['scores','scores2','daily','trials','crew_members']
  loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format($q$
      update public.%I x
         set username = u.raw_user_meta_data ->> 'username'
        from auth.users u
       where u.id = x.user_id
         and coalesce(btrim(u.raw_user_meta_data ->> 'username'), '') <> ''
         and x.username is distinct from (u.raw_user_meta_data ->> 'username')
    $q$, t);
  end loop;
end $$;

-- ============================================================
-- CREWS, WHILE WE ARE HERE
-- Two more things crews.sql predates, both the same shape as the above: a
-- value the client sends that nothing checks.
-- ============================================================

-- Everything below is skipped whole if crews.sql has not been run.
do $$
begin
  if to_regclass('public.crews') is null then
    raise notice 'public.crews does not exist yet - the crew half of this file is skipped';
    return;
  end if;

  -- A default as well as the stamp, so a client that stops sending the column
  -- is not refused by the not-null before the trigger ever runs.
  alter table public.crew_members alter column username set default '';

  -- ---------------- what a crew may be called ----------------
  -- The same 3-18 the client enforces, plus the same character set, so the two
  -- agree. A crew already named something longer keeps its name: this only
  -- applies to rows written from here on, which is what `not valid` means.
  alter table public.crews drop constraint if exists crews_name_sane;
  alter table public.crews add constraint crews_name_sane
    check (char_length(btrim(name)) between 3 and 18
       and name ~ '^[A-Za-z0-9 ._-]+$'
       and char_length(tag) <= 4) not valid;
end $$;

-- The owner is stamped too. The policy already says `auth.uid() = owner` on
-- insert, so this changes nothing about who may create one - it is here so the
-- name and tag are trimmed in one place rather than trusted to arrive tidy.
create or replace function public.crews_guard() returns trigger
  language plpgsql security definer as $$
begin
  if tg_op = 'INSERT' then
    new.owner := auth.uid();
  else
    new.owner := old.owner;
  end if;
  new.name := btrim(new.name);
  new.tag  := btrim(coalesce(new.tag, ''));
  return new;
end $$;

do $$
begin
  if to_regclass('public.crews') is null then return; end if;
  drop trigger if exists crews_guarded on public.crews;
  create trigger crews_guarded before insert or update on public.crews
    for each row execute function public.crews_guard();
end $$;

-- ---------------- an owner who walks out ----------------
-- Hand the crew to whoever has been in it longest, and if there is nobody at
-- all, take the crew down with them. An empty crew holding a name nobody can
-- use is worse than no crew.
create or replace function public.crew_owner_left() returns trigger
  language plpgsql security definer as $$
declare heir uuid;
begin
  if not exists (select 1 from public.crews c where c.id = old.crew_id and c.owner = old.user_id) then
    return old;                       -- an ordinary member leaving: nothing to do
  end if;
  select m.user_id into heir from public.crew_members m
   where m.crew_id = old.crew_id and m.user_id <> old.user_id
   order by m.joined_at asc limit 1;
  if heir is null then
    delete from public.crews where id = old.crew_id;
  else
    update public.crews set owner = heir where id = old.crew_id;
  end if;
  return old;
end $$;

do $$
begin
  if to_regclass('public.crew_members') is null then return; end if;
  drop trigger if exists crew_owner_leaves on public.crew_members;
  create trigger crew_owner_leaves after delete on public.crew_members
    for each row execute function public.crew_owner_left();
end $$;

-- ---------------- crews nobody is in ----------------
-- The orphan case the client used to produce on its own: crewCreate inserts
-- the crew, then inserts the membership as a second request, and a dropped
-- connection between the two left a crew with a name, an owner and no members
-- - and the unique index on lower(name) meant that name was taken by something
-- nobody could join or delete. The client now deletes the crew if the second
-- request fails; this is for the ones already sitting there.
--
-- Not a trigger, because a crew is legitimately memberless for the instant
-- between those two requests. Run it by hand when you want to tidy up:
--
--   delete from public.crews c
--    where not exists (select 1 from public.crew_members m where m.crew_id = c.id)
--      and c.created_at < now() - interval '1 hour';
