-- SoFlo Wheelie Life — cloud saves
-- Paste this whole file into Supabase → SQL Editor → Run.

-- One row per player. The whole game save lives in `data` as JSON, which is
-- exactly the shape the game already keeps in localStorage.
create table if not exists public.saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Row level security: a player can only ever see or touch their own row.
-- This is what makes it safe to ship the anon key in the page.
alter table public.saves enable row level security;

drop policy if exists "read own save"   on public.saves;
drop policy if exists "insert own save" on public.saves;
drop policy if exists "update own save" on public.saves;

create policy "read own save"   on public.saves
  for select using (auth.uid() = user_id);
create policy "insert own save" on public.saves
  for insert with check (auth.uid() = user_id);
create policy "update own save" on public.saves
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Keep updated_at honest even if a client forgets to send it.
create or replace function public.touch_save() returns trigger
  language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists saves_touch on public.saves;
create trigger saves_touch before insert or update on public.saves
  for each row execute function public.touch_save();
