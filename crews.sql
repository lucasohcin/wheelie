-- SoFlo Wheelie Life - crews
-- Run in Supabase > SQL Editor. Safe to run more than once.

create table if not exists public.crews (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  tag        text not null default '',
  owner      uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- one crew per name, case insensitive
create unique index if not exists crews_name_lower on public.crews (lower(name));

create table if not exists public.crew_members (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  crew_id   uuid not null references public.crews(id) on delete cascade,
  username  text not null,
  joined_at timestamptz not null default now()
);
create index if not exists crew_members_crew on public.crew_members (crew_id);

alter table public.crews        enable row level security;
alter table public.crew_members enable row level security;

drop policy if exists "crews are public"     on public.crews;
drop policy if exists "create a crew"        on public.crews;
drop policy if exists "owner edits crew"     on public.crews;
drop policy if exists "owner deletes crew"   on public.crews;
drop policy if exists "roster is public"     on public.crew_members;
drop policy if exists "join a crew"          on public.crew_members;
drop policy if exists "leave a crew"         on public.crew_members;

-- anyone signed in can browse crews and rosters
create policy "crews are public"   on public.crews        for select using (true);
create policy "roster is public"   on public.crew_members for select using (true);

-- you may only create a crew you own, and only edit or delete your own
create policy "create a crew"      on public.crews for insert with check (auth.uid() = owner);
create policy "owner edits crew"   on public.crews for update using (auth.uid() = owner) with check (auth.uid() = owner);
create policy "owner deletes crew" on public.crews for delete using (auth.uid() = owner);

-- you may only add or remove your own membership row
create policy "join a crew"  on public.crew_members for insert with check (auth.uid() = user_id);
create policy "leave a crew" on public.crew_members for delete using (auth.uid() = user_id);

-- Combined standings. Reads the public score table, so it exposes nothing
-- that was not already readable.
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
   group by c.id, c.name, c.tag;

grant select on public.crew_board to anon, authenticated;
