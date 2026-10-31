-- Private messages between members. (No drops, no deletes; the cleanup
-- functions that delete are in 2026-10-30q_messages_cleanup.sql.)
-- Only the sender and recipient can read a message. Admins can't read messages: they only see
-- totals, set how long messages are kept, and delete old ones to free space.

create table if not exists public.dm_messages (
  id                  uuid primary key default gen_random_uuid(),
  sender              uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  recipient           uuid not null references public.profiles (id) on delete cascade,
  body                text not null check (char_length(trim(body)) between 1 and 2000),
  created_at          timestamptz not null default now(),
  read_at             timestamptz,
  hidden_by_sender    boolean not null default false,  -- "delete conversation" removes it for that person only
  hidden_by_recipient boolean not null default false,
  check (sender <> recipient)
);
create index if not exists dm_pair_idx on public.dm_messages (least(sender, recipient), greatest(sender, recipient), created_at desc);
create index if not exists dm_unread_idx on public.dm_messages (recipient) where read_at is null;
create index if not exists dm_created_idx on public.dm_messages (created_at);
alter table public.dm_messages enable row level security;

-- Who sent it and when is stamped by the server; a gentle flood limit.
create or replace function public.stamp_dm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.id := gen_random_uuid();
  new.sender := auth.uid();
  new.created_at := now();
  new.read_at := null;
  new.hidden_by_sender := false;
  new.hidden_by_recipient := false;
  new.body := trim(new.body);
  if (select count(*) from public.dm_messages where sender = new.sender and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'You''re sending messages very quickly. Wait a few minutes and try again.';
  end if;
  if to_regprocedure('private.purge_old_dms()') is not null then perform private.purge_old_dms(); end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'stamp_dm' and tgrelid = 'public.dm_messages'::regclass) then
    create trigger stamp_dm before insert on public.dm_messages for each row execute function public.stamp_dm();
  end if;
end $$;

-- Read: only your own conversations (and not ones you've removed). Nobody else, admins included.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'dm_messages' and policyname = 'dm: only sender and recipient') then
    create policy "dm: only sender and recipient" on public.dm_messages for select to authenticated
      using ((sender = auth.uid() and not hidden_by_sender) or (recipient = auth.uid() and not hidden_by_recipient));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'dm_messages' and policyname = 'dm: approved members send to approved members') then
    create policy "dm: approved members send to approved members" on public.dm_messages for insert to authenticated
      with check (private.is_approved() and sender = auth.uid() and recipient <> auth.uid() and private.is_approved_member(recipient));
  end if;
end $$;
revoke update, delete on public.dm_messages from authenticated, anon;
revoke select, insert on public.dm_messages from anon;
revoke insert, truncate, references, trigger on public.dm_messages from authenticated; -- only the two columns below
grant select on public.dm_messages to authenticated;
grant insert (recipient, body) on public.dm_messages to authenticated;

-- Your conversation list: the other person, the latest message, and how many are unread.
create or replace function public.my_conversations()
returns table (other uuid, other_name text, last_body text, last_at timestamptz, last_from_me boolean, unread int)
language sql stable security definer set search_path = '' as $$
  with mine as (
    select m.*, case when m.sender = auth.uid() then m.recipient else m.sender end as other_id
      from public.dm_messages m
     where private.is_approved()
       and ((m.sender = auth.uid() and not m.hidden_by_sender) or (m.recipient = auth.uid() and not m.hidden_by_recipient))
  ), latest as (
    select distinct on (other_id) other_id, body, created_at, sender = auth.uid() as from_me
      from mine order by other_id, created_at desc
  )
  select l.other_id, coalesce(p.display_name, 'Former member'), left(l.body, 140), l.created_at, l.from_me,
         (select count(*)::int from mine u where u.other_id = l.other_id and u.recipient = auth.uid() and u.read_at is null)
    from latest l left join public.profiles p on p.id = l.other_id
   order by l.created_at desc;
$$;

-- One conversation, newest first, in pages (the read rule above applies).
create or replace function public.dm_thread(other uuid, before timestamptz default null, lim int default 50)
returns setof public.dm_messages language sql stable security invoker set search_path = '' as $$
  select * from public.dm_messages m
   where ((m.sender = auth.uid() and m.recipient = other) or (m.sender = other and m.recipient = auth.uid()))
     and (before is null or m.created_at < before)
   order by m.created_at desc
   limit least(greatest(coalesce(lim, 50), 1), 200);
$$;

create or replace function public.dm_unread_count()
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.dm_messages
   where recipient = auth.uid() and read_at is null and not hidden_by_recipient and private.is_approved();
$$;

create or replace function public.mark_conversation_read(other uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.dm_messages set read_at = now()
   where recipient = auth.uid() and sender = other and read_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- "Delete conversation": hides it for you; the other person keeps their copy.
create or replace function public.hide_conversation(other uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare a int; b int;
begin
  update public.dm_messages set hidden_by_sender = true where sender = auth.uid() and recipient = other;
  get diagnostics a = row_count;
  update public.dm_messages set hidden_by_recipient = true, read_at = coalesce(read_at, now()) where recipient = auth.uid() and sender = other;
  get diagnostics b = row_count;
  return a + b;
end $$;

-- How long messages are kept (admins choose; members are told in the Messages window).
alter table public.album_settings add column if not exists dm_retention_days int
  constraint album_settings_dm_retention_check check (dm_retention_days in (30, 60, 90, 180, 365));
grant update (dm_retention_days) on public.album_settings to authenticated;

-- Admins: totals only, never message text.
create or replace function public.admin_message_stats()
returns table (total int, total_bytes bigint, oldest timestamptz, older_30 int, older_90 int, older_180 int, older_365 int, people int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can see message totals'; end if;
  return query select count(*)::int, coalesce(sum(octet_length(body)), 0)::bigint, min(created_at),
    count(*) filter (where created_at < now() - interval '30 days')::int,
    count(*) filter (where created_at < now() - interval '90 days')::int,
    count(*) filter (where created_at < now() - interval '180 days')::int,
    count(*) filter (where created_at < now() - interval '365 days')::int,
    (select count(distinct x) from (select sender as x from public.dm_messages union select recipient from public.dm_messages) s)::int
  from public.dm_messages;
end $$;

revoke execute on function public.stamp_dm() from public, anon, authenticated;
revoke execute on function public.my_conversations(), public.dm_thread(uuid, timestamptz, int), public.dm_unread_count(),
  public.mark_conversation_read(uuid), public.hide_conversation(uuid), public.admin_message_stats() from public, anon;
grant execute on function public.my_conversations(), public.dm_thread(uuid, timestamptz, int), public.dm_unread_count(),
  public.mark_conversation_read(uuid), public.hide_conversation(uuid), public.admin_message_stats() to authenticated;

-- Live updates: new messages arrive without refreshing (the read rule above applies to these too).
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'dm_messages') then
    alter publication supabase_realtime add table public.dm_messages;
  end if;
end $$;
