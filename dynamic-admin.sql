-- SoFlo Wheelie Life - Dynamic Admin
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.is_admin() from admin.sql and public.is_super() from
-- super-admin.sql.
--
-- ============================================================
-- WHAT THIS IS
-- ------------------------------------------------------------
-- Announcements and events were both one-way: an admin pushes, every player
-- receives, and nobody can answer. Dynamic Admin is the half that answers
-- back. Three tables' worth of it:
--
--   chat       everybody types, everybody reads, admins moderate
--   polls      an admin asks a question, players pick, the tally is live
--   reactions  a heart on a message, a poll, an announcement, or on nothing
--              at all - which everybody riding sees float up their screen
--
-- All of it polls on a beat, like the announcements and events already do.
-- There is no websocket and nothing to keep running. The game works with none
-- of this applied: the chat button says the server has not got it yet, no poll
-- ever appears, and nothing else changes.
--
-- The rule every table here follows, and the one that matters most: the
-- username on a row is stamped by the database from the account that wrote it,
-- never taken from the request. Otherwise the first thing that happens in a
-- global chat is somebody posting as somebody else.
-- ============================================================

-- ============================================================
-- MUTES
-- Moderation needs something between "delete the message" and "delete the
-- account". Its own table rather than a column on a player row, so that a mute
-- expiring needs no job to clear it - it is just a timestamp in the past.
-- ============================================================
create table if not exists public.mutes (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  until    timestamptz not null,
  reason   text not null default '' check (char_length(reason) <= 120),
  muted_by uuid references auth.users(id) on delete set null,
  author   text not null default '',
  at       timestamptz not null default now()
);
alter table public.mutes enable row level security;

drop policy if exists "see own mute"    on public.mutes;
drop policy if exists "admins mute"     on public.mutes;
drop policy if exists "admins remute"   on public.mutes;
drop policy if exists "admins unmute"   on public.mutes;

-- You may read your own, so the game can tell you why you cannot type and for
-- how long. An admin reads all of them to run the list.
create policy "see own mute"  on public.mutes for select
  using (auth.uid() = user_id or public.is_admin());
create policy "admins mute"   on public.mutes for insert with check (public.is_admin());
create policy "admins remute" on public.mutes for update using (public.is_admin());
create policy "admins unmute" on public.mutes for delete using (public.is_admin());

-- security definer for the same reason is_admin() is: the chat trigger has to
-- see a mute belonging to somebody else.
create or replace function public.is_muted(who uuid) returns boolean
  language sql security definer stable as $$
    select exists (select 1 from public.mutes m where m.user_id = who and m.until > now());
  $$;
grant execute on function public.is_muted(uuid) to authenticated;

-- ============================================================
-- CHAT
-- One room, everybody in it. Deliberately not per-crew and not per-world: the
-- population of this game at any one moment is small enough that splitting it
-- into rooms would leave every room empty.
-- ============================================================
create table if not exists public.chat (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  username   text not null default '',
  body       text not null check (char_length(btrim(body)) between 1 and 200),
  created_at timestamptz not null default now()
);
create index if not exists chat_recent on public.chat (id desc);
create index if not exists chat_by_user on public.chat (user_id, created_at desc);
alter table public.chat enable row level security;

drop policy if exists "chat is readable"   on public.chat;
drop policy if exists "post as yourself"   on public.chat;
drop policy if exists "admins delete chat" on public.chat;

-- Signed in to read it. Not `using (true)`: the leaderboard is a list of
-- numbers and is fine in public, but a chat log is people talking, and there
-- is no reason for it to be readable by anybody who has not made an account.
create policy "chat is readable" on public.chat for select
  using (auth.uid() is not null);
create policy "post as yourself" on public.chat for insert
  with check (auth.uid() = user_id);
-- No update policy at all. An edited message in a log other people have
-- already read and reacted to is a way to lie about what was said.
create policy "admins delete chat" on public.chat for delete using (public.is_admin());

-- Who said it, stamped from the account, plus the two limits that keep one
-- person from owning the room: a message every two seconds, fifteen a minute.
-- Both are the server's job. A limit in the client is decoration, because
-- anyone can read the key out of the page source and POST straight at the API.
create or replace function public.chat_guard() returns trigger
  language plpgsql security definer as $$
declare
  since timestamptz;
  n int;
  m record;
begin
  new.user_id := auth.uid();
  if new.user_id is null then
    raise exception 'Sign in to say anything';
  end if;

  select m2.until, m2.reason into m from public.mutes m2
   where m2.user_id = new.user_id and m2.until > now();
  if found then
    raise exception 'You are muted until % %', to_char(m.until, 'HH24:MI'),
      case when coalesce(m.reason,'') = '' then '' else '(' || m.reason || ')' end;
  end if;

  select max(c.created_at) into since from public.chat c where c.user_id = new.user_id;
  if since is not null and since > now() - interval '2 seconds' then
    raise exception 'Slow down a second';
  end if;

  select count(*) into n from public.chat c
   where c.user_id = new.user_id and c.created_at > now() - interval '1 minute';
  if n >= 15 then
    raise exception 'That is enough for one minute';
  end if;

  new.username := coalesce(
    (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = new.user_id),
    'rider');
  new.body := btrim(new.body);
  new.created_at := now();
  return new;
end $$;

drop trigger if exists chat_guarded on public.chat;
create trigger chat_guarded before insert on public.chat
  for each row execute function public.chat_guard();

-- The room is the last few hundred messages, not the whole history. Trimmed
-- from the insert path so there is no scheduled job to forget to set up.
-- `after ... for each statement` so it runs once per insert, not per row.
create or replace function public.chat_trim() returns trigger
  language plpgsql security definer as $$
begin
  delete from public.chat
   where created_at < now() - interval '7 days'
      or id <= (select max(id) - 500 from public.chat);
  return null;
end $$;

drop trigger if exists chat_trimmed on public.chat;
create trigger chat_trimmed after insert on public.chat
  for each statement execute function public.chat_trim();

-- ============================================================
-- POLLS
-- The question an admin asks the whole game. Options live in a text[] rather
-- than a child table: a poll has two to six of them, they are written once and
-- never edited, and a child table would mean two round trips to render one
-- card.
-- ============================================================
create table if not exists public.polls (
  id         bigserial primary key,
  question   text not null check (char_length(btrim(question)) between 1 and 160),
  options    text[] not null check (
               array_length(options, 1) between 2 and 6
               and array_position(options, null::text) is null),
  created_by uuid references auth.users(id) on delete set null,
  author     text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- Same reasoning as the events window: somebody will open a poll and forget
  -- about it, and a poll that never closes is a poll nobody answers twice.
  constraint polls_window check (expires_at > created_at
                             and expires_at <= created_at + interval '14 days')
);
create index if not exists polls_live on public.polls (expires_at desc);
alter table public.polls enable row level security;

drop policy if exists "polls are public"  on public.polls;
drop policy if exists "admins ask"        on public.polls;
drop policy if exists "admins edit polls" on public.polls;
drop policy if exists "admins end polls"  on public.polls;

create policy "polls are public"  on public.polls for select using (true);
create policy "admins ask"        on public.polls for insert with check (public.is_admin());
create policy "admins edit polls" on public.polls for update using (public.is_admin());
create policy "admins end polls"  on public.polls for delete using (public.is_admin());

-- Signed by the account, like an event is, so nobody can ask a question under
-- somebody else's name. The option list is cleaned here too: blank entries are
-- dropped rather than rendered as a button with no label on it.
create or replace function public.polls_guard() returns trigger
  language plpgsql security definer as $$
declare cleaned text[];
begin
  -- Only on the way in. An admin closing somebody else's poll early is an
  -- UPDATE, and re-stamping the author there would quietly put their name on a
  -- question they did not ask.
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.author := coalesce(
      (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = auth.uid()),
      '');
  else
    new.created_by := old.created_by;
    new.author := old.author;
  end if;
  select array_agg(left(btrim(o), 60)) into cleaned
    from unnest(new.options) o where btrim(coalesce(o, '')) <> '';
  if cleaned is null or array_length(cleaned, 1) < 2 then
    raise exception 'A poll needs at least two options with something written on them';
  end if;
  new.options := cleaned;
  new.question := btrim(new.question);
  return new;
end $$;

drop trigger if exists polls_authored on public.polls;
create trigger polls_authored before insert or update on public.polls
  for each row execute function public.polls_guard();

-- ---------------- votes ----------------
-- One row per rider per poll, so changing your mind is an update rather than a
-- second vote. The primary key is what enforces that, not the client.
create table if not exists public.poll_votes (
  poll_id  bigint not null references public.polls(id) on delete cascade,
  user_id  uuid   not null references auth.users(id) on delete cascade,
  choice   int    not null check (choice >= 0 and choice < 6),
  voted_at timestamptz not null default now(),
  primary key (poll_id, user_id)
);
create index if not exists poll_votes_tally on public.poll_votes (poll_id, choice);
alter table public.poll_votes enable row level security;

drop policy if exists "see own vote"  on public.poll_votes;
drop policy if exists "cast own vote" on public.poll_votes;
drop policy if exists "change own vote" on public.poll_votes;

-- You can read your own vote and nobody else's. The numbers everyone sees come
-- from poll_tally below, which returns counts and never names. A poll where
-- the room can see who voted for what is a poll people answer differently.
create policy "see own vote"    on public.poll_votes for select using (auth.uid() = user_id);
create policy "cast own vote"   on public.poll_votes for insert with check (auth.uid() = user_id);
create policy "change own vote" on public.poll_votes for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Refuses a vote on a poll that has closed. Without it the tally keeps moving
-- after the result has been read out, which is the one thing a closed poll is
-- supposed to stop.
create or replace function public.poll_votes_guard() returns trigger
  language plpgsql security definer as $$
declare p record;
begin
  new.user_id := auth.uid();
  select o.expires_at, array_length(o.options, 1) as n into p
    from public.polls o where o.id = new.poll_id;
  if not found then
    raise exception 'That poll is gone';
  end if;
  if p.expires_at <= now() then
    raise exception 'That poll has closed';
  end if;
  if new.choice < 0 or new.choice >= p.n then
    raise exception 'That is not one of the answers';
  end if;
  new.voted_at := now();
  return new;
end $$;

drop trigger if exists poll_votes_guarded on public.poll_votes;
create trigger poll_votes_guarded before insert or update on public.poll_votes
  for each row execute function public.poll_votes_guard();

-- Counts only, never names. security definer because the select policy above
-- deliberately hides everyone else's row from the caller.
create or replace function public.poll_tally(pid bigint)
  returns table (choice int, votes bigint)
  language sql security definer stable as $$
    select v.choice, count(*)::bigint
      from public.poll_votes v
     where v.poll_id = pid
     group by v.choice
     order by v.choice;
  $$;
grant execute on function public.poll_tally(bigint) to authenticated;

-- ============================================================
-- REACTIONS
-- A heart on a thing. Four kinds of thing, and one non-thing:
--
--   'chat'  target_id is a chat message id
--   'poll'  target_id is a poll id
--   'bcast' target_id is a broadcast id
--   'world' target_id is 0 - a cheer sent to nobody in particular, which
--           everybody currently riding sees float up their screen
--
-- The first three are counted, so each rider may leave one of each emoji on
-- each thing and take it back by tapping again. 'world' is not counted and is
-- meant to be repeated, so it is rate limited instead.
-- ============================================================
create table if not exists public.reactions (
  id         bigserial primary key,
  kind       text   not null check (kind in ('chat','poll','bcast','world')),
  target_id  bigint not null default 0,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  username   text   not null default '',
  emoji      text   not null check (emoji in ('heart','fire','laugh','clap','wow','skull')),
  created_at timestamptz not null default now()
);
-- One of each emoji per rider per thing - but only for the kinds that are
-- counted. A partial unique index is what lets 'world' repeat while the others
-- cannot, without needing a second table that would be the same six columns.
drop index if exists public.reactions_one_each;
create unique index reactions_one_each on public.reactions (kind, target_id, user_id, emoji)
  where kind <> 'world';
create index if not exists reactions_target on public.reactions (kind, target_id);
create index if not exists reactions_recent on public.reactions (created_at desc);
alter table public.reactions enable row level security;

drop policy if exists "reactions are readable" on public.reactions;
drop policy if exists "react as yourself"      on public.reactions;
drop policy if exists "take back own"          on public.reactions;
drop policy if exists "admins clear reactions" on public.reactions;

create policy "reactions are readable" on public.reactions for select
  using (auth.uid() is not null);
create policy "react as yourself" on public.reactions for insert
  with check (auth.uid() = user_id);
-- Taking one back is a delete of your own row. Admins can clear anybody's,
-- which is what makes a brigaded message cleanable without deleting it.
create policy "take back own" on public.reactions for delete
  using (auth.uid() = user_id or public.is_admin());

create or replace function public.reactions_guard() returns trigger
  language plpgsql security definer as $$
declare last_at timestamptz;
begin
  new.user_id := auth.uid();
  if new.user_id is null then
    raise exception 'Sign in first';
  end if;
  if public.is_muted(new.user_id) then
    raise exception 'You are muted';
  end if;
  -- A cheer is meant to be spammed a bit - that is the point of it - but not
  -- faster than it can be seen. Twice a second, and no more than forty in a
  -- minute, which is a long enough burst to be fun and short enough that one
  -- person cannot fill everybody's screen for an hour.
  if new.kind = 'world' then
    new.target_id := 0;
    select max(r.created_at) into last_at from public.reactions r
     where r.user_id = new.user_id and r.kind = 'world';
    if last_at is not null and last_at > now() - interval '500 milliseconds' then
      raise exception 'Easy';
    end if;
    if (select count(*) from public.reactions r
         where r.user_id = new.user_id and r.kind = 'world'
           and r.created_at > now() - interval '1 minute') >= 40 then
      raise exception 'That is enough cheering for one minute';
    end if;
  end if;
  new.username := coalesce(
    (select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = new.user_id),
    'rider');
  new.created_at := now();
  return new;
end $$;

drop trigger if exists reactions_guarded on public.reactions;
create trigger reactions_guarded before insert on public.reactions
  for each row execute function public.reactions_guard();

-- Cheers are only ever read a minute back, so they are swept on the way in for
-- the same reason chat is. Counted reactions are kept: they belong to the
-- message they are sitting on, and chat's own trim takes them with it when the
-- message goes (on delete cascade is not available across a polymorphic
-- reference, so this deletes the orphans instead).
create or replace function public.reactions_trim() returns trigger
  language plpgsql security definer as $$
begin
  delete from public.reactions
   where kind = 'world' and created_at < now() - interval '5 minutes';
  delete from public.reactions r
   where r.kind = 'chat'
     and not exists (select 1 from public.chat c where c.id = r.target_id);
  return null;
end $$;

drop trigger if exists reactions_trimmed on public.reactions;
create trigger reactions_trimmed after insert on public.reactions
  for each statement execute function public.reactions_trim();

-- ============================================================
-- WHAT AN ADMIN NEEDS THAT POLICIES CANNOT SAY
-- ============================================================
-- Muting takes a username, like every other admin power in this game, and
-- usernames live in auth.users where an ordinary admin cannot read them.
create or replace function public.chat_mute(uname text, minutes int, why text)
  returns text language plpgsql security definer as $$
declare
  tgt uuid;
  who text := btrim(coalesce(uname, ''));
  mins int := greatest(1, least(20160, coalesce(minutes, 60)));   -- a minute to a fortnight
begin
  if not public.is_admin() then
    raise exception 'Only an admin can mute somebody';
  end if;
  select u.id into tgt from auth.users u
   where lower(u.raw_user_meta_data ->> 'username') = lower(who) limit 1;
  if tgt is null then
    select s.user_id into tgt from public.scores s where lower(s.username) = lower(who) limit 1;
  end if;
  if tgt is null then
    raise exception 'No rider called "%"', who;
  end if;
  if tgt = auth.uid() then
    raise exception 'Muting yourself is not a moderation strategy';
  end if;
  -- An ordinary admin cannot mute an admin. Two of them muting each other back
  -- and forth is not something the game should have to arbitrate.
  if exists (select 1 from public.admins a where a.user_id = tgt) and not public.is_super() then
    raise exception '% is an admin. Only a super admin can mute one.', who;
  end if;
  if exists (select 1 from public.admins a where a.user_id = tgt and a.super) then
    raise exception '% is a super admin.', who;
  end if;

  insert into public.mutes (user_id, until, reason, muted_by, author)
  values (tgt, now() + (interval '1 minute' * mins), left(btrim(coalesce(why, '')), 120), auth.uid(),
          coalesce((select u.raw_user_meta_data ->> 'username' from auth.users u where u.id = auth.uid()), ''))
  on conflict (user_id) do update
     set until = excluded.until, reason = excluded.reason,
         muted_by = excluded.muted_by, author = excluded.author, at = now();

  return who || ' is muted for ' || mins || ' minutes';
end $$;
grant execute on function public.chat_mute(text, int, text) to authenticated;

create or replace function public.chat_unmute(uname text)
  returns text language plpgsql security definer as $$
declare tgt uuid; who text := btrim(coalesce(uname, ''));
begin
  if not public.is_admin() then
    raise exception 'Only an admin can unmute somebody';
  end if;
  select u.id into tgt from auth.users u
   where lower(u.raw_user_meta_data ->> 'username') = lower(who) limit 1;
  if tgt is null then
    raise exception 'No rider called "%"', who;
  end if;
  delete from public.mutes where user_id = tgt;
  return who || ' can talk again';
end $$;
grant execute on function public.chat_unmute(text) to authenticated;

-- The mute list, with names on it. `mutes` itself holds uuids, and the panel
-- needs to show who they are.
create or replace function public.mute_roster()
  returns table (username text, until timestamptz, reason text, author text)
  language sql security definer stable as $$
    select coalesce(u.raw_user_meta_data ->> 'username', '(deleted)'),
           m.until, m.reason, m.author
      from public.mutes m
      left join auth.users u on u.id = m.user_id
     where public.is_admin() and m.until > now()
     order by m.until desc;
  $$;
grant execute on function public.mute_roster() to authenticated;

-- ---------------- how long am I muted for? ----------------
-- The chat box greys itself out rather than letting somebody type a paragraph
-- and then be refused by the trigger. The "see own mute" policy already allows
-- this as a plain select; it is a function only so the client has one shape to
-- read instead of two.
create or replace function public.my_mute()
  returns table (until timestamptz, reason text)
  language sql security definer stable as $$
    select m.until, m.reason from public.mutes m
     where m.user_id = auth.uid() and m.until > now();
  $$;
grant execute on function public.my_mute() to authenticated;
