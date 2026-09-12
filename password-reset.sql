-- SoFlo Wheelie Life - password reset
-- Run in Supabase > SQL Editor. Safe to run more than once.
-- Depends on public.is_super() from super-admin.sql for the admin half only;
-- the player-facing half stands on its own.
--
-- ============================================================
-- WHY THIS IS NOT THE NORMAL SUPABASE FLOW
-- ------------------------------------------------------------
-- Supabase resets a password by mailing a link to the address on the account.
-- This game's accounts are usernames mapped to `someone@wheelie.local`, an
-- address space that does not exist and cannot receive mail, so that flow has
-- never been available here. Up to now the answer to "I forgot my password"
-- was for an admin to set a new one from the Supabase dashboard by hand.
--
-- What players actually have is the optional recovery email they typed at
-- signup, which is sitting in `raw_user_meta_data`. So that is the secret this
-- checks: username plus recovery email, and if the pair matches, a new
-- password is set directly.
--
-- BE CLEAR ABOUT WHAT THAT MEANS. This is not as strong as a mailed link.
-- Anyone who knows a rider's username AND the exact recovery email address
-- they signed up with can take the account, because nothing here proves the
-- person asking controls that inbox. It is one shared secret instead of two
-- factors. The mitigations are:
--
--   * It is rate limited - five wrong answers for a username in an hour and
--     that username stops answering for an hour, so the email cannot be
--     guessed a few thousand times a minute.
--   * The failure message is identical whether the username does not exist,
--     has no recovery email, or has a different one. Nothing here tells an
--     attacker they got half of it right.
--   * A successful reset deletes every existing session for that account, so
--     if somebody else WAS in there, this throws them out.
--   * An account with no recovery email cannot be reset this way at all. Those
--     still go through a super admin.
--
-- If you would rather not accept that trade, do not run this file. Sign-in,
-- signup and everything else keep working exactly as they do now; the game
-- shows "password reset is not set up on this server" and points the player at
-- an admin. The change-your-password-while-signed-in button in the game does
-- not depend on this file either - that one goes through Supabase's own
-- authenticated endpoint and is unconditionally safe.
-- ============================================================

-- bcrypt. Supabase ships pgcrypto in the `extensions` schema.
create extension if not exists pgcrypto with schema extensions;

-- ---------------- the attempt log ----------------
-- What makes the rate limit possible, and an audit trail worth having: if an
-- account is ever taken, this says when and how many tries it took.
-- Nobody may read it but the functions below, which are security definer.
create table if not exists public.reset_log (
  id       bigserial primary key,
  uname    text not null,
  ok       boolean not null default false,
  at       timestamptz not null default now()
);
create index if not exists reset_log_recent on public.reset_log (lower(uname), at desc);
alter table public.reset_log enable row level security;
-- No policies at all, deliberately. RLS with no policy denies everything to
-- anon and authenticated; the security definer functions below bypass it.

-- ---------------- the reset itself ----------------
-- Runs as the definer so it can write auth.users, which no ordinary role may
-- touch. Granted to `anon` because the entire point is that the person calling
-- it cannot sign in.
create or replace function public.password_reset(uname text, recovery text, new_pass text)
  returns text language plpgsql security definer
  -- Pinned, for two reasons. A security definer function that inherits the
  -- caller's search_path can be pointed at a shadowed `crypt`; and pgcrypto
  -- lands in `extensions` on Supabase but in `public` on a plain Postgres, so
  -- naming both is what makes this file run on either.
  set search_path = public, extensions, pg_temp as $$
declare
  who  text := lower(btrim(coalesce(uname, '')));
  mail text := lower(btrim(coalesce(recovery, '')));
  tgt  uuid;
  fails int;
begin
  if who = '' or mail = '' then
    raise exception 'Fill in both your username and your recovery email';
  end if;
  -- Matches the client and Supabase's own minimum. Checked here too, because
  -- the client is not the thing enforcing it.
  if length(coalesce(new_pass, '')) < 8 then
    raise exception 'Your new password must be at least 8 characters';
  end if;

  -- Five wrong answers in an hour and this username stops answering. Counted
  -- before the attempt is made, so the fifth failure is the last one that gets
  -- a look at the email.
  select count(*) into fails from public.reset_log r
   where lower(r.uname) = who and not r.ok and r.at > now() - interval '1 hour';
  if fails >= 5 then
    raise exception 'Too many attempts on that account. Try again in an hour.';
  end if;

  select u.id into tgt from auth.users u
   where lower(u.raw_user_meta_data ->> 'username') = who
     and lower(btrim(coalesce(u.raw_user_meta_data ->> 'recovery_email', ''))) = mail
     and coalesce(btrim(u.raw_user_meta_data ->> 'recovery_email'), '') <> ''
   limit 1;

  if tgt is null then
    insert into public.reset_log (uname, ok) values (who, false);
    -- One message for every kind of miss. A different error for "no such
    -- rider" would turn this into a username oracle, and a different one for
    -- "wrong email" would let an attacker confirm the username and then work
    -- on the address.
    raise exception 'That username and recovery email do not match an account';
  end if;

  update auth.users
     set encrypted_password = crypt(new_pass, gen_salt('bf')),
         updated_at = now()
   where id = tgt;

  -- Whoever was signed in as this account is signed out by it. If the reason
  -- for the reset was that somebody else got in, leaving their session alive
  -- would make the reset pointless.
  begin
    delete from auth.sessions       where user_id = tgt;
    delete from auth.refresh_tokens where user_id = tgt;
  exception
    -- Older GoTrue schemas do not have auth.sessions. The password is already
    -- changed by this point and that is the part that matters.
    when undefined_table then null;
  end;

  insert into public.reset_log (uname, ok) values (who, true);
  return 'Password changed. Sign in with your new one.';
end $$;
grant execute on function public.password_reset(text, text, text) to anon, authenticated;

-- ---------------- an admin setting one by hand ----------------
-- The way back in for a rider who never added a recovery email. Super admin
-- only, for the same reason account_delete is: it is total control of somebody
-- else's account, and an ordinary admin's powers are all capped and reversible.
create or replace function public.admin_set_password(uname text, new_pass text)
  returns text language plpgsql security definer
  set search_path = public, extensions, pg_temp as $$
declare
  tgt uuid;
  who text := btrim(coalesce(uname, ''));
begin
  if not public.is_super() then
    raise exception 'Only a super admin can set somebody else''s password';
  end if;
  if length(coalesce(new_pass, '')) < 8 then
    raise exception 'The new password must be at least 8 characters';
  end if;
  tgt := public.super_find(who);
  if tgt is null then
    raise exception 'No account called "%"', who;
  end if;
  -- Another super's account is not yours to take, the same rule account_delete
  -- already applies. Demoting them first is a deliberate second decision.
  if tgt <> auth.uid() and exists (select 1 from public.admins a where a.user_id = tgt and a.super) then
    raise exception '% is another super admin. Take their super away first.', who;
  end if;

  update auth.users
     set encrypted_password = crypt(new_pass, gen_salt('bf')),
         updated_at = now()
   where id = tgt;

  -- Not for your own account: you are holding one of those sessions.
  if tgt <> auth.uid() then
    begin
      delete from auth.sessions       where user_id = tgt;
      delete from auth.refresh_tokens where user_id = tgt;
    exception when undefined_table then null;
    end;
  end if;

  insert into public.reset_log (uname, ok) values (who, true);
  return 'Set a new password for ' || who || ' and signed them out everywhere';
end $$;
grant execute on function public.admin_set_password(text, text) to authenticated;

-- ---------------- housekeeping ----------------
-- The log is only ever read an hour back. Trim it so it does not grow forever.
-- Called from the reset path rather than scheduled, so there is nothing to
-- forget to set up.
create or replace function public.reset_log_trim() returns trigger
  language plpgsql security definer as $$
begin
  delete from public.reset_log where at < now() - interval '30 days';
  return null;
end $$;

drop trigger if exists reset_log_trimmed on public.reset_log;
create trigger reset_log_trimmed after insert on public.reset_log
  for each statement execute function public.reset_log_trim();
