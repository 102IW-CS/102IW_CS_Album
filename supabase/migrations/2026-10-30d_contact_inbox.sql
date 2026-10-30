-- Contact inbox for the public contact page. (No drops.)
-- Anyone (signed in or not) can send a message; only admins can read, mark or delete them.
-- Validation and a flood limit run on the server, so they can't be skipped by calling the API directly.

create table if not exists public.contact_messages (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) between 1 and 80),
  email      text not null check (char_length(email) between 5 and 160 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone      text check (char_length(phone) <= 40),
  topic      text not null default 'other' check (topic in ('photo-site', 'website', 'app', 'other')),
  message    text not null check (char_length(trim(message)) between 10 and 4000),
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists contact_messages_created_idx on public.contact_messages (created_at desc);
alter table public.contact_messages enable row level security;

-- Server sets the id, time and unread flag, and slows down floods.
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
  return new;
end $$;
create trigger stamp_contact_message before insert on public.contact_messages
  for each row execute function public.stamp_contact_message();
revoke execute on function public.stamp_contact_message() from public, anon, authenticated; -- trigger only

create policy "contact: anyone can send" on public.contact_messages
  for insert to anon, authenticated with check (true);
create policy "contact: admins read" on public.contact_messages
  for select to authenticated using (private.is_admin());
create policy "contact: admins mark read" on public.contact_messages
  for update to authenticated using (private.is_admin()) with check (private.is_admin());
create policy "contact: admins delete" on public.contact_messages
  for delete to authenticated using (private.is_admin());

revoke all on public.contact_messages from anon, authenticated;
grant insert (name, email, phone, topic, message) on public.contact_messages to anon, authenticated;
grant select, delete on public.contact_messages to authenticated;
grant update (read) on public.contact_messages to authenticated;

alter publication supabase_realtime add table public.contact_messages;
