-- Photo Share: database setup for Supabase
-- Run once in Supabase → SQL Editor → New query → paste all → Run.
-- Safe to run again: it updates what exists instead of failing.
--
-- Who sees what:
--   • Members see their own photos and albums, plus any album the admin marks "shared".
--   • Admins see everything.
--   • Accounts waiting for approval see nothing (except the owner's contact details).

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

-- Helpers the access rules use. They live in a "private" schema the web API doesn't expose.
-- "security definer" lets them read profiles without opening the profiles table to everyone.
create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.is_approved()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved');
$$;

create or replace function private.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved' and is_admin);
$$;

-- People can read their own member row; admins can read all of them.
drop policy if exists "read own or admin" on public.profiles;
create policy "read own or admin" on public.profiles
  for select to authenticated using (id = auth.uid() or private.is_admin());

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
  if not private.is_admin() then raise exception 'Only admins can change member status'; end if;
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
create index if not exists photos_thumb_path_idx on public.photos (thumb_path);
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

-- ============ Albums ============
-- Members create their own (private) albums. Only an admin can mark an album "shared",
-- which lets every member see it and add photos to it.
-- Deleting an album never deletes photos by itself: they move to "Unsorted".
create table if not exists public.albums (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(trim(name)) between 1 and 80),
  description     text check (char_length(description) <= 300),
  cover_photo_id  uuid,
  created_by      uuid references public.profiles (id) on delete set null default auth.uid(),
  created_by_name text,
  created_at      timestamptz not null default now()
);
alter table public.albums add column if not exists shared boolean not null default false;
alter table public.albums enable row level security;

alter table public.photos add column if not exists album_id uuid references public.albums (id) on delete set null;
create index if not exists photos_album_idx on public.photos (album_id, created_at desc);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'albums_cover_photo_fk') then
    alter table public.albums add constraint albums_cover_photo_fk
      foreign key (cover_photo_id) references public.photos (id) on delete set null;
  end if;
end $$;

create or replace function public.stamp_album()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_by := auth.uid();
  new.created_by_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  new.shared := coalesce(new.shared, false) and private.is_admin(); -- only admins create shared albums
  return new;
end $$;
drop trigger if exists stamp_album on public.albums;
create trigger stamp_album before insert on public.albums
  for each row execute function public.stamp_album();

create or replace function public.guard_album_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.shared is distinct from old.shared and not private.is_admin() then
    raise exception 'Only admins can change who sees an album';
  end if;
  return new;
end $$;
drop trigger if exists guard_album_update on public.albums;
create trigger guard_album_update before update on public.albums
  for each row execute function public.guard_album_update();

-- ============ Visibility helpers ============
-- Can the signed-in person file photos into this album? (their own, a shared one, or any if admin)
create or replace function private.can_use_album(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.albums a
    where a.id = target and (a.shared or a.created_by = auth.uid() or private.is_admin()));
$$;

-- Can the signed-in person see this photo? (their own, one in a shared album, or any if admin)
create or replace function private.can_view_photo(photo_owner uuid, photo_album uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin() or photo_owner = auth.uid()
    or exists (select 1 from public.albums a where a.id = photo_album and a.shared));
$$;

-- Same question for a stored file (full size or preview), looked up by its path.
create or replace function private.can_view_file(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin()
    or split_part(object_name, '/', 1) = auth.uid()::text
    or exists (select 1 from public.photos p join public.albums a on a.id = p.album_id
               where a.shared and (p.path = object_name or p.thumb_path = object_name)));
$$;

-- ============ Photo rules ============
-- Remove rules from earlier versions of this script.
drop policy if exists "approved can view" on public.photos;
drop policy if exists "approved can add own" on public.photos;
drop policy if exists "owner or admin can delete" on public.photos;
drop policy if exists "approved can delete photos" on public.photos;
drop policy if exists "owner or admin can move photos" on public.photos;
drop policy if exists "approved can move photos" on public.photos;

drop policy if exists "photos: see own, shared, or all if admin" on public.photos;
create policy "photos: see own, shared, or all if admin" on public.photos
  for select to authenticated using (private.can_view_photo(uploader, album_id));

drop policy if exists "photos: add own into usable album" on public.photos;
create policy "photos: add own into usable album" on public.photos
  for insert to authenticated
  with check (private.is_approved() and split_part(path, '/', 1) = auth.uid()::text
              and (album_id is null or private.can_use_album(album_id)));

-- Moving between albums: your own photos (admins: any), into an album you can use. Nothing else can change.
revoke update on public.photos from authenticated, anon;
grant update (album_id) on public.photos to authenticated;
drop policy if exists "photos: move own" on public.photos;
create policy "photos: move own" on public.photos
  for update to authenticated
  using (private.is_approved() and (uploader = auth.uid() or private.is_admin()))
  with check (private.is_approved() and (uploader = auth.uid() or private.is_admin())
              and (album_id is null or private.can_use_album(album_id)));

-- Deleting: any photo you can see (for clearing out space).
drop policy if exists "photos: delete what you can see" on public.photos;
create policy "photos: delete what you can see" on public.photos
  for delete to authenticated using (private.can_view_photo(uploader, album_id));

-- ============ Album rules ============
drop policy if exists "approved can view albums" on public.albums;
drop policy if exists "approved can create albums" on public.albums;
drop policy if exists "creator or admin can edit albums" on public.albums;
drop policy if exists "creator or admin can delete albums" on public.albums;

drop policy if exists "albums: see own, shared, or all if admin" on public.albums;
create policy "albums: see own, shared, or all if admin" on public.albums
  for select to authenticated using (private.is_approved() and (shared or created_by = auth.uid() or private.is_admin()));

drop policy if exists "albums: approved can create" on public.albums;
create policy "albums: approved can create" on public.albums
  for insert to authenticated with check (private.is_approved());

-- Rename/delete: your own private albums; shared albums only by an admin.
drop policy if exists "albums: owner or admin can edit" on public.albums;
create policy "albums: owner or admin can edit" on public.albums
  for update to authenticated
  using (private.is_approved() and (private.is_admin() or (created_by = auth.uid() and not shared)))
  with check (private.is_approved() and (private.is_admin() or (created_by = auth.uid() and not shared)));

drop policy if exists "albums: owner or admin can delete" on public.albums;
create policy "albums: owner or admin can delete" on public.albums
  for delete to authenticated
  using (private.is_approved() and (private.is_admin() or (created_by = auth.uid() and not shared)));

revoke update on public.albums from authenticated, anon;
grant update (name, description, cover_photo_id, shared) on public.albums to authenticated;

-- ============ File storage ============
-- Private bucket: files are only reachable through short-lived signed links.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 52428800,
        array['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'image/heic', 'image/heif', 'image/bmp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "photos: approved can view" on storage.objects;
drop policy if exists "photos: owner or admin can delete" on storage.objects;
drop policy if exists "photos: approved can delete" on storage.objects;

drop policy if exists "photos: view visible files" on storage.objects;
create policy "photos: view visible files" on storage.objects
  for select to authenticated using (bucket_id = 'photos' and private.can_view_file(name));

-- Each person uploads only into their own folder (<user id>/...).
drop policy if exists "photos: upload to own folder" on storage.objects;
create policy "photos: upload to own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and private.is_approved() and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "photos: delete visible files" on storage.objects;
create policy "photos: delete visible files" on storage.objects
  for delete to authenticated using (bucket_id = 'photos' and private.can_view_file(name));

-- ============ Admin: member list ============
create or replace function public.admin_list_members()
returns table (id uuid, display_name text, email text, status text, is_admin boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can list members'; end if;
  return query select p.id, p.display_name, p.email, p.status, p.is_admin, p.created_at
               from public.profiles p order by (p.status = 'pending') desc, p.created_at desc;
end $$;

-- ============ Album settings ============
-- One row: the album owner's name and how people can reach them.
-- Signed-in people (including those waiting for approval) can read it; only admins can change it.
-- The actual name/phone/email are entered in the site's Album settings, not in this public file.
create table if not exists public.album_settings (
  id            int primary key default 1 check (id = 1),
  owner_name    text check (char_length(owner_name) <= 80),
  contact_phone text check (char_length(contact_phone) <= 40),
  contact_email text check (char_length(contact_email) <= 120),
  updated_at    timestamptz not null default now()
);
alter table public.album_settings enable row level security;
insert into public.album_settings (id) values (1) on conflict (id) do nothing;

drop policy if exists "signed-in can read settings" on public.album_settings;
create policy "signed-in can read settings" on public.album_settings
  for select to authenticated using (true);

drop policy if exists "admin can edit settings" on public.album_settings;
create policy "admin can edit settings" on public.album_settings
  for update to authenticated using (private.is_admin()) with check (private.is_admin());

revoke insert, update, delete on public.album_settings from authenticated, anon;
revoke select on public.album_settings from anon;
grant update (owner_name, contact_phone, contact_email) on public.album_settings to authenticated;

-- ============ Who may run what ============
-- Postgres lets everyone run new functions by default; narrow that down.
revoke execute on function private.is_approved(), private.is_admin(), private.can_use_album(uuid),
  private.can_view_photo(uuid, uuid), private.can_view_file(text) from public, anon;
grant execute on function private.is_approved(), private.is_admin(), private.can_use_album(uuid),
  private.can_view_photo(uuid, uuid), private.can_view_file(text) to authenticated;
revoke execute on function public.handle_new_user(), public.stamp_photo(), public.stamp_album(),
  public.guard_album_update() from public, anon, authenticated; -- triggers only
revoke execute on function public.set_member_status(uuid, text), public.admin_list_members() from public, anon;
grant execute on function public.set_member_status(uuid, text), public.admin_list_members() to authenticated;

-- Older versions of this script kept the helpers in public; remove those copies.
drop function if exists public.is_approved();
drop function if exists public.is_admin();

-- ============ Catch-up for accounts created before this script ran ============
insert into public.profiles (id, display_name, email, status, is_admin)
select u.id,
       left(coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1)), 60),
       u.email, 'pending', false
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

-- If there's no admin yet, the earliest account becomes the admin.
update public.profiles set status = 'approved', is_admin = true
where id = (select u.id from auth.users u join public.profiles p on p.id = u.id order by u.created_at limit 1)
  and not exists (select 1 from public.profiles where is_admin);

-- ============ Live updates ============
-- Lets open pages hear about new, moved or deleted photos and albums right away.
do $$
declare t text;
begin
  foreach t in array array['photos', 'albums'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
