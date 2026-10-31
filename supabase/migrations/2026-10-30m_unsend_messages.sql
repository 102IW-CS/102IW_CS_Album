-- Unsend (for everyone, within 24 hours) and delete-for-me for single messages. (No drops, no deletes.)
-- Unsending wipes the text in the database; both people then see "… unsent a message".
-- "Delete for me" hides one message for one person; it's removed for good once both have hidden it
-- (the cleanup in 2026-10-30q_messages_cleanup.sql already deletes rows both people have hidden).

alter table public.dm_messages add column if not exists unsent_at timestamptz;

create or replace function public.unsend_message(msg uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.dm_messages
     set body = 'Message unsent', unsent_at = now()
   where id = msg and sender = auth.uid() and unsent_at is null
     and created_at > now() - interval '24 hours';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You can unsend only your own messages, within 24 hours of sending them.'; end if;
end $$;

create or replace function public.hide_message(msg uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare n int; m int;
begin
  update public.dm_messages set hidden_by_sender = true where id = msg and sender = auth.uid();
  get diagnostics n = row_count;
  update public.dm_messages set hidden_by_recipient = true, read_at = coalesce(read_at, now()) where id = msg and recipient = auth.uid();
  get diagnostics m = row_count;
  if n + m = 0 then raise exception 'That message isn''t in your conversations.'; end if;
end $$;

-- New messages always start "not unsent", whatever the page sends.
create or replace function public.stamp_dm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.id := gen_random_uuid();
  new.sender := auth.uid();
  new.created_at := now();
  new.read_at := null;
  new.unsent_at := null;
  new.hidden_by_sender := false;
  new.hidden_by_recipient := false;
  new.body := trim(new.body);
  if (select count(*) from public.dm_messages where sender = new.sender and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'You''re sending messages very quickly. Wait a few minutes and try again.';
  end if;
  if to_regprocedure('private.purge_old_dms()') is not null then perform private.purge_old_dms(); end if;
  return new;
end $$;

revoke execute on function public.unsend_message(uuid), public.hide_message(uuid) from public, anon;
grant execute on function public.unsend_message(uuid), public.hide_message(uuid) to authenticated;
