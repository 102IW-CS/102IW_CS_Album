-- Private messages: cleanup functions (these contain DELETE, so they're kept in their own file).
-- Removes messages both people have deleted, and messages older than the admin's setting.
create or replace function private.purge_old_dms()
returns integer language plpgsql security definer set search_path = '' as $$
declare keep_days int; gone int;
begin
  select dm_retention_days into keep_days from public.album_settings where id = 1;
  delete from public.dm_messages
   where (hidden_by_sender and hidden_by_recipient)
      or (keep_days is not null and created_at < now() - make_interval(days => keep_days));
  get diagnostics gone = row_count;
  return gone;
end $$;
revoke execute on function private.purge_old_dms() from public, anon, authenticated;

-- Admins free up space: delete every message older than N days (they never see the text).
create or replace function public.admin_purge_messages(older_than_days int)
returns integer language plpgsql security definer set search_path = '' as $$
declare gone int;
begin
  if not private.is_admin() then raise exception 'Only admins can delete messages'; end if;
  if older_than_days is null or older_than_days < 0 then raise exception 'Choose how old'; end if;
  delete from public.dm_messages where created_at < now() - make_interval(days => older_than_days);
  get diagnostics gone = row_count;
  return gone + private.purge_old_dms();
end $$;
revoke execute on function public.admin_purge_messages(int) from public, anon;
grant execute on function public.admin_purge_messages(int) to authenticated;
