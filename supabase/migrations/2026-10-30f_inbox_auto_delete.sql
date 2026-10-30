-- Inbox auto-delete. (No drops.)
-- The admin chooses how long to keep READ contact messages (30, 60, 90, 180 or 365 days, or never).
-- Unread messages are never auto-deleted, so nothing disappears before someone has seen it.
-- Cleanup runs in the database: whenever a new message arrives, and whenever an admin opens the Inbox.

alter table public.album_settings add column if not exists inbox_retention_days int
  constraint album_settings_inbox_retention_check check (inbox_retention_days in (30, 60, 90, 180, 365));
grant update (inbox_retention_days) on public.album_settings to authenticated;

-- Does the actual cleanup; returns how many messages were removed. Not callable by visitors directly.
create or replace function private.purge_read_messages()
returns integer language plpgsql security definer set search_path = '' as $$
declare keep_days int; gone int;
begin
  select inbox_retention_days into keep_days from public.album_settings where id = 1;
  if keep_days is null then return 0; end if; -- "Never"
  delete from public.contact_messages
   where read and created_at < now() - make_interval(days => keep_days);
  get diagnostics gone = row_count;
  return gone;
end $$;
revoke execute on function private.purge_read_messages() from public, anon, authenticated;

-- What the site calls when an admin opens the Inbox or changes the setting.
create or replace function public.purge_read_messages()
returns integer language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can clean up the inbox'; end if;
  return private.purge_read_messages();
end $$;
revoke execute on function public.purge_read_messages() from public, anon;
grant execute on function public.purge_read_messages() to authenticated;

-- New contact messages also trigger the cleanup (same checks as before, plus one line).
create or replace function public.stamp_contact_message()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.id := gen_random_uuid();
  new.created_at := now();
  new.read := false;
  new.email := lower(trim(new.email));
  new.name := trim(new.name);
  if (select count(*) from public.contact_messages where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'The inbox is busy right now. Please email instead.';
  end if;
  if (select count(*) from public.contact_messages
      where email = new.email and created_at > now() - interval '1 day') >= 3 then
    raise exception 'You have already sent a few messages today. Please email instead.';
  end if;
  perform private.purge_read_messages();
  return new;
end $$;
