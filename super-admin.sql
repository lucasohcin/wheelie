-- SoFlo Wheelie Life - the super admin
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.admins and public.grants from admin.sql / admin-limits.sql.
--
-- An admin is a moderator. They announce things, start events, gift inside the
-- caps in admin-limits.sql, and clear a bio. Those caps exist because an admin
-- is somebody you trust a lot but not completely.
--
-- A super admin is the owner. Every power below has no safe cap, so rather
-- than inventing one the database asks a single question first - are you the
-- super - and refuses everybody else. Same rule as the rest of the game: the
-- panel in the page is a door, and this file is the lock.
--
-- There is exactly one way to become the FIRST super admin, and it is the
-- statement at the very bottom of this file, typed into the SQL editor by
-- somebody holding the project password. After that it can all be done from
-- inside the game, which is the point of the thing.

-- ---------------- who is super ----------------
-- A column on admins rather than a table of its own, so that a super admin is
-- always also an admin and every existing policy that says is_admin() keeps
-- working for them without being listed twice.
alter table public.admins add column if not exists super boolean not null default false;

-- security definer for the same reason is_admin() is: it has to read rows the
-- caller's own policy would hide.
create or replace function public.is_super() returns boolean
  language sql security definer stable as $$
    select exists (select 1 from public.admins a where a.user_id = auth.uid() and a.super);
  $$;
grant execute on function public.is_super() to anon, authenticated;

-- The panel reads its own admins row to find out, which the existing
-- "admins readable" policy already allows - auth.uid() = user_id.

-- ---------------- finding an account ----------------
-- Every super power takes a username, so they all need to turn one into a uuid.
-- auth.users is the authority; public.scores is the fallback for an account
-- from before usernames were kept in the signup metadata.
--
-- NOT granted to anybody. It reads auth.users, so it stays internal to the
-- functions below, which each check is_super() for themselves. Postgres grants
-- execute to PUBLIC on a new function by default, hence the revoke.
create or replace function public.super_find(uname text) returns uuid
  language sql security definer stable as $$
    select coalesce(
      (select u.id from auth.users u
        where lower(u.raw_user_meta_data ->> 'username') = lower(btrim(uname)) limit 1),
      (select s.user_id from public.scores s
        where lower(s.username) = lower(btrim(uname)) limit 1));
  $$;
revoke execute on function public.super_find(text) from public, anon, authenticated;

-- What the panel shows before it offers to delete somebody. A destructive
-- button with no way to check who it is pointed at is a trap.
create or replace function public.super_lookup(uname text)
  returns table (user_id uuid, username text, is_admin boolean, is_super boolean,
                 joined timestamptz, last_seen timestamptz, best bigint)
  language plpgsql security definer stable as $$
declare tgt uuid;
begin
  if not public.is_super() then
    raise exception 'Only a super admin can look up an account';
  end if;
  tgt := public.super_find(uname);
  if tgt is null then return; end if;
  return query
    select u.id,
           coalesce(u.raw_user_meta_data ->> 'username', '')::text,
           exists (select 1 from public.admins a where a.user_id = u.id),
           exists (select 1 from public.admins a where a.user_id = u.id and a.super),
           u.created_at,
           u.last_sign_in_at,
           coalesce((select s.best from public.scores s where s.user_id = u.id), 0)::bigint
      from auth.users u
     where u.id = tgt;
end $$;
grant execute on function public.super_lookup(text) to authenticated;

-- ---------------- admins, from inside the game ----------------
-- The roster. A non-super gets zero rows rather than an error, because this is
-- also what the panel calls to decide whether to draw the card at all.
create or replace function public.admin_roster()
  returns table (user_id uuid, username text, super boolean, since timestamptz)
  language sql security definer stable as $$
    select a.user_id,
           coalesce(u.raw_user_meta_data ->> 'username', '(no username)')::text,
           a.super,
           a.created_at
      from public.admins a
      left join auth.users u on u.id = a.user_id
     where public.is_super()
     order by a.super desc, a.created_at;
  $$;
grant execute on function public.admin_roster() to authenticated;

-- Promote, demote, and hand over the keys. There are no insert, update or
-- delete policies on public.admins at all, so this function is the only way in
-- and every caller goes past the is_super() check at the top of it.
--
-- make_super implies make_admin: the column lives on the admins row, so there
-- is no such thing as a super who is not an admin.
create or replace function public.admin_set(uname text, make_admin boolean, make_super boolean)
  returns text language plpgsql security definer as $$
declare
  tgt   uuid;
  who   text    := btrim(coalesce(uname, ''));
  adm   boolean := coalesce(make_admin, false) or coalesce(make_super, false);
  sup   boolean := coalesce(make_super, false);
begin
  if not public.is_super() then
    raise exception 'Only a super admin can change who is an admin';
  end if;
  tgt := public.super_find(who);
  if tgt is null then
    raise exception 'No account called "%" - they have to have signed up first', who;
  end if;

  -- You may promote yourself to nothing and demote yourself to nothing. A
  -- super who taps the wrong row and takes their own super away has locked
  -- themselves out of this function and has to go back to the SQL editor, so
  -- the database simply does not let it happen from in here.
  if tgt = auth.uid() and not sup then
    raise exception 'You cannot take your own super admin away from inside the game';
  end if;

  if not adm then
    delete from public.admins where user_id = tgt;
    return who || ' is not an admin any more';
  end if;

  insert into public.admins (user_id, super) values (tgt, sup)
    on conflict (user_id) do update set super = excluded.super;
  return who || (case when sup then ' is now a SUPER admin - they can do everything you can'
                      else ' is now an admin' end);
end $$;
grant execute on function public.admin_set(text, boolean, boolean) to authenticated;

-- ---------------- deleting an account ----------------
-- Every table in this game hangs off auth.users with `on delete cascade`, so
-- one delete takes the save, the scores, the profile, the crew membership, the
-- daily and trial runs, the Afterburn row, any admin rights and any unclaimed
-- grants with it. Deleting the rows by hand instead would mean this file has
-- to be edited every time a table is added, and the day somebody forgets is
-- the day an account half exists.
--
-- The whole function is one transaction, so if the auth delete is refused
-- nothing at all is removed. There is no half-deleted account.
create or replace function public.account_delete(uname text)
  returns text language plpgsql security definer as $$
declare
  tgt uuid;
  who text := btrim(coalesce(uname, ''));
begin
  if not public.is_super() then
    raise exception 'Only a super admin can delete an account';
  end if;
  tgt := public.super_find(who);
  if tgt is null then
    raise exception 'No account called "%"', who;
  end if;
  if tgt = auth.uid() then
    raise exception 'This will not delete your own account. Do that from Supabase if you mean it.';
  end if;
  -- Two supers deleting each other is a race nobody wins. Demote them first,
  -- which is a deliberate second decision.
  if exists (select 1 from public.admins a where a.user_id = tgt and a.super) then
    raise exception '% is another super admin. Take their super away first.', who;
  end if;

  delete from auth.users where id = tgt;
  return 'Deleted ' || who || ' and everything they had';
exception
  -- Fires only if this database has not granted the function owner rights on
  -- auth.users. My own checks above raise P0001 and do not land here.
  when insufficient_privilege then
    raise exception 'This database will not let the function delete from auth.users. Run it as the postgres role, or delete the account from Supabase > Authentication.';
end $$;
grant execute on function public.account_delete(text) to authenticated;

-- ---------------- gifts, with the caps taken off ----------------
-- Two new kinds a super can send, both of them Afterburn, both of them things
-- admin-limits.sql deliberately refuses an ordinary admin:
--   embers - the second world's currency
--   w2key  - the road out, for somebody who has not done five rebirths
alter table public.grants add column if not exists sudo boolean not null default false;

-- The kind list is a column check constraint, so its name is generated. Find
-- it rather than guessing, or a re-run adds a second constraint next to the
-- old one and every new kind is refused by whichever is stricter.
do $$
declare c record;
begin
  for c in select con.conname from pg_constraint con
            where con.conrelid = 'public.grants'::regclass and con.contype = 'c'
              and pg_get_constraintdef(con.oid) ilike '%kind%'
  loop
    execute format('alter table public.grants drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.grants add constraint grants_kind_check
  check (kind in ('coins','bike','xp','pass','trick','embers','w2key'));

-- The same guard as before with one door cut into the top of it. Everything
-- below that door is a rule about admins, and the owner of the game is not one
-- of the people those rules are protecting it from.
create or replace function public.grants_guard() returns trigger
  language plpgsql security definer as $$
declare
  -- running totals for this admin over the last 24 hours
  coins_day   bigint;
  coins_to    bigint;
  xp_day      bigint;
  rows_day    bigint;
  -- the limits themselves. Prefixed, because plpgsql identifiers are
  -- case-insensitive: lim_xp_day and lim_rows_day collided with the xp_day and
  -- rows_day above them and the function would not compile.
  lim_coin_one constant bigint := 100000;   -- per recipient, per day
  lim_coin_day constant bigint := 250000;   -- per admin, per day, everyone
  lim_xp_one   constant bigint := 5000;
  lim_xp_day   constant bigint := 20000;
  lim_rows_day constant bigint := 20;
begin
  -- the sender is who the request is from, never what the request claims, and
  -- so is the authority they sent it with
  new.sent_by = auth.uid();
  new.sudo = public.is_super();

  if new.amount < 0 then
    raise exception 'Amount cannot be negative';
  end if;

  -- The super admin door. No self-gift rule, no daily budget, no cap on a
  -- single gift, and Afterburn is theirs to hand out. The receiving game reads
  -- `sudo` off the row and is what actually lets an Afterburn bike land in the
  -- Afterburn garage, so this flag is not decoration.
  if new.sudo then
    return new;
  end if;

  if new.kind in ('embers','w2key') then
    raise exception 'Afterburn is the super admins to give, not an admins';
  end if;

  if new.user_id = auth.uid() then
    raise exception 'An admin cannot gift themselves';
  end if;

  -- Afterburn is off limits. 88 is W2_BIKE0 in the game; keep the two in step.
  if new.kind = 'bike' and new.amount >= 88 then
    raise exception 'Afterburn bikes are not an admins to give';
  end if;

  select count(*) into rows_day from public.grants g
    where g.sent_by = auth.uid() and g.created_at > now() - interval '24 hours';
  if rows_day >= lim_rows_day then
    raise exception 'Daily limit: % gifts in 24 hours', lim_rows_day;
  end if;

  if new.kind = 'coins' then
    if new.amount > lim_coin_one then
      raise exception 'The most you can gift at once is % coins', lim_coin_one;
    end if;
    select coalesce(sum(g.amount), 0) into coins_to from public.grants g
      where g.sent_by = auth.uid() and g.user_id = new.user_id
        and g.kind = 'coins' and g.created_at > now() - interval '24 hours';
    if coins_to + new.amount > lim_coin_one then
      raise exception 'That rider has already had % of their % coin daily limit from you',
        coins_to, lim_coin_one;
    end if;
    select coalesce(sum(g.amount), 0) into coins_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'coins'
        and g.created_at > now() - interval '24 hours';
    if coins_day + new.amount > lim_coin_day then
      raise exception 'You have given % of your % coins for today', coins_day, lim_coin_day;
    end if;
  end if;

  if new.kind = 'xp' then
    if new.amount > lim_xp_one then
      raise exception 'The most you can gift at once is % XP', lim_xp_one;
    end if;
    select coalesce(sum(g.amount), 0) into xp_day from public.grants g
      where g.sent_by = auth.uid() and g.kind = 'xp'
        and g.created_at > now() - interval '24 hours';
    if xp_day + new.amount > lim_xp_day then
      raise exception 'You have given % of your % XP for today', xp_day, lim_xp_day;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists grants_guarded on public.grants;
create trigger grants_guarded before insert on public.grants
  for each row execute function public.grants_guard();

-- ---------------- become the first super admin ----------------
-- Change the username to yours and run these two lines. You must have signed
-- in and played once, so that there is an account to find.
--
--   insert into public.admins (user_id, super)
--   select id, true from auth.users
--    where lower(raw_user_meta_data ->> 'username') = lower('YOUR_USERNAME')
--   on conflict (user_id) do update set super = true;
--
-- If it says 0 rows, the username did not match and nothing happened. Either
-- way, run this next - it should print your row with super = true:
--
--   select a.super, u.raw_user_meta_data ->> 'username' as username
--     from public.admins a join auth.users u on u.id = a.user_id;
--
-- From here on, everybody else is promoted from the panel in the game.
