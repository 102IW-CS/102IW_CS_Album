-- Real email addresses. (No drops.)
-- The proof that an address works is Supabase's "Confirm email" (a link/code sent to it),
-- which needs custom SMTP. On top of that:
--  * throwaway / reserved email domains are refused when an account is created;
--  * nobody can be approved until they've confirmed their email;
--  * admins and moderators can see who has confirmed.

create or replace function private.is_blocked_email(addr text)
returns boolean language sql immutable set search_path = '' as $$
  select lower(split_part(coalesce(addr, ''), '@', 2)) = any (array[
      'mailinator.com','guerrillamail.com','guerrillamail.net','guerrillamail.org','guerrillamailblock.com','sharklasers.com','grr.la',
      '10minutemail.com','10minutemail.net','temp-mail.org','temp-mail.io','tempmail.com','tempmail.net','tempmailo.com','tempmail.dev',
      'yopmail.com','yopmail.net','yopmail.fr','trashmail.com','trashmail.de','trashmail.net','getnada.com','nada.email','maildrop.cc',
      'dispostable.com','throwawaymail.com','fakeinbox.com','mailnesia.com','emailondeck.com','mohmal.com','burnermail.io','mytemp.email',
      'tempail.com','moakt.com','spamgourmet.com','mintemail.com','mailcatch.com','mailpoof.com','tempr.email','discard.email',
      'getairmail.com','inboxkitten.com','emailfake.com','fakemail.net','tempinbox.com','spambox.us','mailtemp.net',
      'example.com','example.org','example.net','test.com'])
    or lower(split_part(coalesce(addr, ''), '@', 2)) ~ '\.(test|example|invalid|localhost|local)$';
$$;
revoke execute on function private.is_blocked_email(text) from public, anon;
grant execute on function private.is_blocked_email(text) to authenticated;

-- New sign-ups: same as before, plus the throwaway-address check.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare first_user boolean;
begin
  if private.is_blocked_email(new.email) then
    raise exception 'Please use your regular, permanent email address.';
  end if;
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, display_name, email, status, is_admin)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1)), 60),
    new.email,
    case when first_user then 'approved' else 'pending' end,
    first_user
  );
  return new;
end $$;

-- Approving requires a confirmed email (everything else unchanged).
create or replace function public.set_member_status(target uuid, new_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_moderator() then raise exception 'Only admins and moderators can change member status'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own status'; end if;
  if new_status not in ('pending', 'approved', 'blocked') then raise exception 'Unknown status'; end if;
  if not private.is_admin() and exists (select 1 from public.profiles where id = target and (is_admin or is_moderator)) then
    raise exception 'Only an admin can change the status of another admin or moderator';
  end if;
  if new_status = 'approved' and exists (select 1 from auth.users where id = target and email_confirmed_at is null) then
    raise exception 'This person hasn''t confirmed their email address yet';
  end if;
  update public.profiles set status = new_status where id = target;
end $$;

-- Who has confirmed their email, and when they last signed in (admins and moderators).
create or replace function public.member_email_status()
returns table (id uuid, email_confirmed boolean, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_moderator() then raise exception 'Only admins and moderators can see this'; end if;
  return query select u.id, u.email_confirmed_at is not null, u.last_sign_in_at
    from auth.users u join public.profiles p on p.id = u.id;
end $$;
revoke execute on function public.member_email_status() from public, anon;
grant execute on function public.member_email_status() to authenticated;
