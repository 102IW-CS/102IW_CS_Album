-- Automatic approval after email confirmation, switchable by admins. (No drops.)
-- auto_approve: when on, a pending account becomes approved the moment its email is confirmed.
-- auto_approve_domains: optional comma-separated list (e.g. 'us.af.mil, gmail.com'); when set,
--   only addresses at those domains (or their subdomains) are approved automatically.
-- Only a real confirmation counts (a confirmation email was sent), so if "Confirm email" is
-- ever switched off in Supabase, nobody is approved automatically.

alter table public.album_settings add column if not exists auto_approve boolean not null default false;
alter table public.album_settings add column if not exists auto_approve_domains text
  constraint album_settings_auto_domains_check check (char_length(auto_approve_domains) <= 500);
grant update (auto_approve, auto_approve_domains) on public.album_settings to authenticated;
grant select (auto_approve) on public.album_settings to anon; -- so the sign-up form can describe what happens

create or replace function private.email_domain_allowed(addr text, domains text)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(trim(domains), '') = ''
      or exists (
        select 1 from unnest(string_to_array(lower(domains), ',')) d
         where trim(both ' @' from d) <> ''
           and (lower(split_part(addr, '@', 2)) = trim(both ' @' from d)
                or lower(split_part(addr, '@', 2)) like '%.' || trim(both ' @' from d)));
$$;

create or replace function private.auto_approve_on_confirm()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  if old.email_confirmed_at is not null or new.email_confirmed_at is null then return new; end if;
  if new.confirmation_sent_at is null then return new; end if; -- confirmed by email, not auto-confirmed
  select auto_approve, auto_approve_domains into s from public.album_settings where id = 1;
  if coalesce(s.auto_approve, false) and private.email_domain_allowed(new.email, s.auto_approve_domains) then
    update public.profiles set status = 'approved' where id = new.id and status = 'pending';
  end if;
  return new;
end $$;
revoke execute on function private.auto_approve_on_confirm() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_confirmed' and tgrelid = 'auth.users'::regclass) then
    create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
      for each row execute function private.auto_approve_on_confirm();
  end if;
end $$;
