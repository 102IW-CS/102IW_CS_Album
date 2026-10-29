-- Photo Share: database setup for Supabase
-- Run once in Supabase → SQL Editor → New query → paste all → Run.
-- Safe to run again: it updates what exists instead of failing.

-- ============ Members ============
-- One row per person who signs up. New people start as 'pending' until an admin approves them.
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60),
  email        text,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'blocked')),
  is_admin     boolean not null default false,
  created_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- Create the member row automatically at sign-up.
-- The very first person to sign up becomes the approved admin (that should be you).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare first_user boolean;
begin
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- Helpers the access rules use. "security definer" lets them read profiles without
-- opening the profiles table to everyone.
create or replace function public.is_approved()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved');
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved' and is_admin);
$$;

-- People can read their own member row; admins can read all of them.
drop policy if exists "read own or admin" on public.profiles;
create policy "read own or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());

-- People may change only their own display name. Status and admin flags change
-- only through set_member_status() below, which checks that the caller is an admin.
revoke update on public.profiles from authenticated, anon;
grant update (display_name) on public.profiles to authenticated;
drop policy if exists "edit own name" on public.profiles;
create policy "edit own name" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.set_member_status(target uuid, new_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Only admins can change member status'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own status'; end if;
  if new_status not in ('pending', 'approved', 'blocked') then raise exception 'Unknown status'; end if;
  update public.profiles set status = new_status where id = target;
end $$;

-- ============ Photos ============
create table if not exists public.photos (
  id            uuid primary key default gen_random_uuid(),
  path          text not null unique,          -- full-size file in the "photos" bucket
  thumb_path    text,                           -- small preview in the same bucket
  file_name     text not null check (char_length(file_name) between 1 and 120),
  content_type  text,
  size_bytes    bigint check (size_bytes >= 0),
  width         int,
  height        int,
  uploader      uuid references public.profiles (id) on delete set null default auth.uid(),
  uploader_name text,
  created_at    timestamptz not null default now()
);
create index if not exists photos_created_at_idx on public.photos (created_at desc);
alter table public.photos enable row level security;

-- Stamp who uploaded and when on the server, so nobody can fake it from the browser.
create or replace function public.stamp_photo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.uploader := auth.uid();
  new.uploader_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  return new;
end $$;
drop trigger if exists stamp_photo on public.photos;
create trigger stamp_photo before insert on public.photos
  for each row execute function public.stamp_photo();

drop policy if exists "approved can view" on public.photos;
create policy "approved can view" on public.photos
  for select to authenticated using (public.is_approved());

drop policy if exists "approved can add own" on public.photos;
create policy "approved can add own" on public.photos
  for insert to authenticated
  with check (public.is_approved() and split_part(path, '/', 1) = auth.uid()::text);

drop policy if exists "owner or admin can delete" on public.photos;
create policy "owner or admin can delete" on public.photos
  for delete to authenticated using (uploader = auth.uid() or public.is_admin());

-- ============ File storage ============
-- Private bucket: files are only reachable through short-lived signed links.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 52428800,
        array['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/heic', 'image/heif', 'image/bmp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Everyone approved can view; each person uploads only into their own folder (<user id>/...);
-- people delete their own files, admins can delete any.
drop policy if exists "photos: approved can view" on storage.objects;
create policy "photos: approved can view" on storage.objects
  for select to authenticated using (bucket_id = 'photos' and public.is_approved());

drop policy if exists "photos: upload to own folder" on storage.objects;
create policy "photos: upload to own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and public.is_approved() and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "photos: owner or admin can delete" on storage.objects;
create policy "photos: owner or admin can delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ============ Admin: member list ============
create or replace function public.admin_list_members()
returns table (id uuid, display_name text, email text, status text, is_admin boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Only admins can list members'; end if;
  return query select p.id, p.display_name, p.email, p.status, p.is_admin, p.created_at
               from public.profiles p order by (p.status = 'pending') desc, p.created_at desc;
end $$;

revoke execute on function public.set_member_status(uuid, text) from anon;
revoke execute on function public.admin_list_members() from anon;

-- ============ Live updates ============
-- Lets open pages hear about new or deleted photos right away.
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'photos') then
    alter publication supabase_realtime add table public.photos;
  end if;
end $$;
