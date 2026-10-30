-- Photo Share: database setup for Supabase
-- Run once in Supabase → SQL Editor → New query → paste all → Run.
-- Safe to run again: it updates what exists instead of failing.
--
-- Who sees what:
--   • Members see their own photos and albums, plus anything shared with them: with everyone,
--     with them by name, or through an invite link they opened.
--   • Whoever created an album or added a photo (or an admin) decides how it's shared.
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
alter table public.profiles add column if not exists is_moderator boolean not null default false;
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

-- Moderators help with membership: approving, declining and turning off accounts.
-- They don't see other people's private photos and can't change roles.
create or replace function private.is_moderator()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved' and (is_admin or is_moderator));
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
  if not private.is_moderator() then raise exception 'Only admins and moderators can change member status'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own status'; end if;
  if new_status not in ('pending', 'approved', 'blocked') then raise exception 'Unknown status'; end if;
  if not private.is_admin() and exists (select 1 from public.profiles where id = target and (is_admin or is_moderator)) then
    raise exception 'Only an admin can change the status of another admin or moderator';
  end if;
  update public.profiles set status = new_status where id = target;
end $$;

-- Admins make someone a member, moderator or admin. Nobody can change their own role,
-- so there is always at least one admin.
create or replace function public.set_member_role(target uuid, new_role text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can change roles'; end if;
  if target = auth.uid() then raise exception 'You can''t change your own role'; end if;
  if new_role not in ('member', 'moderator', 'admin') then raise exception 'Unknown role'; end if;
  if new_role <> 'member' and not exists (select 1 from public.profiles where id = target and status = 'approved') then
    raise exception 'Approve this account before giving it a role';
  end if;
  update public.profiles set is_admin = (new_role = 'admin'), is_moderator = (new_role = 'moderator') where id = target;
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
-- Members create their own albums (private at first). The creator or an admin can share an album
-- with everyone, with specific members, or by invite link. People who can see an album can also add
-- their own photos to it. Deleting an album never deletes photos by itself: they move to "Unsorted".
create table if not exists public.albums (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(trim(name)) between 1 and 80),
  description     text check (char_length(description) <= 300),
  cover_photo_id  uuid,
  created_by      uuid references public.profiles (id) on delete set null default auth.uid(),
  created_by_name text,
  created_at      timestamptz not null default now()
);
alter table public.albums add column if not exists shared boolean not null default false; -- shared with everyone
alter table public.albums enable row level security;

alter table public.photos add column if not exists album_id uuid references public.albums (id) on delete set null;
alter table public.photos add column if not exists shared boolean not null default false; -- single photo shared with everyone
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
  new.shared := coalesce(new.shared, false);
  return new;
end $$;
drop trigger if exists stamp_album on public.albums;
create trigger stamp_album before insert on public.albums
  for each row execute function public.stamp_album();

-- Earlier versions only let admins change sharing; the album's creator can now do it too.
drop trigger if exists guard_album_update on public.albums;
drop function if exists public.guard_album_update();

-- ============ Sharing with specific members ============
-- One row = one album or one photo shared with one member.
create table if not exists public.shares (
  id         uuid primary key default gen_random_uuid(),
  album_id   uuid references public.albums (id) on delete cascade,
  photo_id   uuid references public.photos (id) on delete cascade,
  member     uuid not null references public.profiles (id) on delete cascade,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(album_id, photo_id) = 1)
);
create unique index if not exists shares_album_member_uq on public.shares (album_id, member) where album_id is not null;
create unique index if not exists shares_photo_member_uq on public.shares (photo_id, member) where photo_id is not null;
create index if not exists shares_member_idx on public.shares (member);
alter table public.shares enable row level security;

create or replace function public.stamp_share()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_by := auth.uid();
  new.created_at := now();
  return new;
end $$;
drop trigger if exists stamp_share on public.shares;
create trigger stamp_share before insert on public.shares
  for each row execute function public.stamp_share();

-- ============ Invite links ============
-- A secret link to an album or photo. Whoever opens it while signed in (including someone who just
-- created an account) gets the item shared with them. They still need admin approval to see anything.
create table if not exists public.share_links (
  token           text primary key,
  album_id        uuid references public.albums (id) on delete cascade,
  photo_id        uuid references public.photos (id) on delete cascade,
  created_by      uuid references public.profiles (id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '30 days',
  revoked         boolean not null default false,
  check (num_nonnulls(album_id, photo_id) = 1)
);
alter table public.share_links enable row level security;

create or replace function public.stamp_share_link()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- 256 random bits, generated on the server
  new.token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  new.created_by := auth.uid();
  new.created_by_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  new.expires_at := now() + interval '30 days';
  new.revoked := false;
  return new;
end $$;
drop trigger if exists stamp_share_link on public.share_links;
create trigger stamp_share_link before insert on public.share_links
  for each row execute function public.stamp_share_link();

-- ============ Visibility helpers ============
-- Can the signed-in person see this album? (own, shared with everyone, shared with them, or admin)
-- Anyone who can see an album can also add their own photos to it.
create or replace function private.can_see_album(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.albums a
    where a.id = target and (private.is_admin() or a.created_by = auth.uid() or a.shared
      or exists (select 1 from public.shares s where s.album_id = a.id and s.member = auth.uid())));
$$;

-- Can they rename, delete or share this album? (its creator or an admin)
create or replace function private.can_manage_album(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.albums a where a.id = target and (private.is_admin() or a.created_by = auth.uid()));
$$;

-- Can they share or move this photo? (whoever added it, or an admin)
create or replace function private.can_manage_photo(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.photos p where p.id = target and (private.is_admin() or p.uploader = auth.uid()));
$$;

create or replace function private.can_manage_target(album uuid, photo uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when album is not null then private.can_manage_album(album) else private.can_manage_photo(photo) end;
$$;

-- Can they see this photo? (own, shared with everyone, shared with them, in an album they can see, or admin)
create or replace function private.can_view_photo(photo uuid, photo_owner uuid, photo_album uuid, photo_shared boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin() or photo_owner = auth.uid() or photo_shared
    or exists (select 1 from public.shares s where s.photo_id = photo and s.member = auth.uid())
    or (photo_album is not null and private.can_see_album(photo_album)));
$$;

-- Can they delete this photo? Only whoever added it, or an admin. Everyone else can request removal.
create or replace function private.can_delete_photo(photo_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (private.is_admin() or photo_owner = auth.uid());
$$;

-- The same questions for stored files (full size or preview), looked up by path.
create or replace function private.can_view_file(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin() or split_part(object_name, '/', 1) = auth.uid()::text
    or exists (select 1 from public.photos p
               where (p.path = object_name or p.thumb_path = object_name)
                 and private.can_view_photo(p.id, p.uploader, p.album_id, p.shared)));
$$;

-- Files live in their uploader's folder, so: your own folder, or an admin.
create or replace function private.can_delete_file(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (private.is_admin() or split_part(object_name, '/', 1) = auth.uid()::text);
$$;

-- Can they ask for this album or photo to be removed? (they can see it but don't control it)
create or replace function private.can_request_removal(album uuid, photo uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and not private.can_manage_target(album, photo) and (
    case when album is not null then private.can_see_album(album)
         else exists (select 1 from public.photos p where p.id = photo
                      and private.can_view_photo(p.id, p.uploader, p.album_id, p.shared)) end);
$$;

create or replace function private.is_approved_member(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = target and status = 'approved');
$$;

-- ============ Photo rules ============
-- Remove rules from earlier versions of this script.
drop policy if exists "approved can view" on public.photos;
drop policy if exists "approved can add own" on public.photos;
drop policy if exists "owner or admin can delete" on public.photos;
drop policy if exists "approved can delete photos" on public.photos;
drop policy if exists "owner or admin can move photos" on public.photos;
drop policy if exists "approved can move photos" on public.photos;
drop policy if exists "photos: delete what you can see" on public.photos;

drop policy if exists "photos: see own, shared, or all if admin" on public.photos;
create policy "photos: see own, shared, or all if admin" on public.photos
  for select to authenticated using (private.can_view_photo(id, uploader, album_id, shared));

drop policy if exists "photos: add own into usable album" on public.photos;
create policy "photos: add own into usable album" on public.photos
  for insert to authenticated
  with check (private.is_approved() and split_part(path, '/', 1) = auth.uid()::text
              and (album_id is null or private.can_see_album(album_id)));

-- Moving and sharing: your own photos (admins: any), into an album you can see. Nothing else can change.
revoke update on public.photos from authenticated, anon;
grant update (album_id, shared) on public.photos to authenticated;
drop policy if exists "photos: move own" on public.photos;
create policy "photos: move own" on public.photos
  for update to authenticated
  using (private.is_approved() and (uploader = auth.uid() or private.is_admin()))
  with check (private.is_approved() and (uploader = auth.uid() or private.is_admin())
              and (album_id is null or private.can_see_album(album_id)));

drop policy if exists "photos: delete own, in own album, or admin" on public.photos;
drop policy if exists "photos: delete own or admin" on public.photos;
create policy "photos: delete own or admin" on public.photos
  for delete to authenticated using (private.can_delete_photo(uploader));

-- ============ Album rules ============
drop policy if exists "approved can view albums" on public.albums;
drop policy if exists "approved can create albums" on public.albums;
drop policy if exists "creator or admin can edit albums" on public.albums;
drop policy if exists "creator or admin can delete albums" on public.albums;

drop policy if exists "albums: see own, shared, or all if admin" on public.albums;
create policy "albums: see own, shared, or all if admin" on public.albums
  for select to authenticated using (private.can_see_album(id));

drop policy if exists "albums: approved can create" on public.albums;
create policy "albums: approved can create" on public.albums
  for insert to authenticated with check (private.is_approved());

drop policy if exists "albums: owner or admin can edit" on public.albums;
create policy "albums: owner or admin can edit" on public.albums
  for update to authenticated
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid()))
  with check (private.is_approved() and (private.is_admin() or created_by = auth.uid()));

drop policy if exists "albums: owner or admin can delete" on public.albums;
create policy "albums: owner or admin can delete" on public.albums
  for delete to authenticated
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid()));

revoke update on public.albums from authenticated, anon;
grant update (name, description, cover_photo_id, shared) on public.albums to authenticated;

-- ============ Share rules ============
-- See shares of things you manage, and shares made to you.
drop policy if exists "shares: see own or managed" on public.shares;
create policy "shares: see own or managed" on public.shares
  for select to authenticated using (member = auth.uid() or private.can_manage_target(album_id, photo_id));

-- Share things you manage with approved members (not yourself).
drop policy if exists "shares: add for managed items" on public.shares;
create policy "shares: add for managed items" on public.shares
  for insert to authenticated
  with check (private.can_manage_target(album_id, photo_id) and member <> auth.uid()
              and private.is_approved_member(member));

-- Stop sharing (the sharer/admin), or remove something shared with you.
drop policy if exists "shares: remove managed or own" on public.shares;
create policy "shares: remove managed or own" on public.shares
  for delete to authenticated using (member = auth.uid() or private.can_manage_target(album_id, photo_id));

revoke update on public.shares from authenticated, anon;

-- ============ Invite link rules ============
drop policy if exists "links: see managed" on public.share_links;
create policy "links: see managed" on public.share_links
  for select to authenticated using (private.can_manage_target(album_id, photo_id));

drop policy if exists "links: create for managed" on public.share_links;
create policy "links: create for managed" on public.share_links
  for insert to authenticated with check (private.can_manage_target(album_id, photo_id));

drop policy if exists "links: turn off managed" on public.share_links;
create policy "links: turn off managed" on public.share_links
  for update to authenticated
  using (private.can_manage_target(album_id, photo_id)) with check (private.can_manage_target(album_id, photo_id));

drop policy if exists "links: delete managed" on public.share_links;
create policy "links: delete managed" on public.share_links
  for delete to authenticated using (private.can_manage_target(album_id, photo_id));

revoke update on public.share_links from authenticated, anon;
grant update (revoked) on public.share_links to authenticated;

-- ============ Removal requests ============
-- Someone who was shared an album or photo can ask its owner (or an admin) to remove it.
create table if not exists public.removal_requests (
  id                uuid primary key default gen_random_uuid(),
  album_id          uuid references public.albums (id) on delete cascade,
  photo_id          uuid references public.photos (id) on delete cascade,
  requested_by      uuid references public.profiles (id) on delete cascade,
  requested_by_name text,
  reason            text check (char_length(reason) <= 300),
  created_at        timestamptz not null default now(),
  check (num_nonnulls(album_id, photo_id) = 1)
);
create unique index if not exists removal_album_uq on public.removal_requests (album_id, requested_by) where album_id is not null;
create unique index if not exists removal_photo_uq on public.removal_requests (photo_id, requested_by) where photo_id is not null;
alter table public.removal_requests enable row level security;

create or replace function public.stamp_removal_request()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.requested_by := auth.uid();
  new.requested_by_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  return new;
end $$;
drop trigger if exists stamp_removal_request on public.removal_requests;
create trigger stamp_removal_request before insert on public.removal_requests
  for each row execute function public.stamp_removal_request();

-- The requester and whoever controls the item can see a request; either can withdraw/dismiss it.
drop policy if exists "removal: see own or managed" on public.removal_requests;
create policy "removal: see own or managed" on public.removal_requests
  for select to authenticated using (requested_by = auth.uid() or private.can_manage_target(album_id, photo_id));
drop policy if exists "removal: ask" on public.removal_requests;
create policy "removal: ask" on public.removal_requests
  for insert to authenticated with check (private.can_request_removal(album_id, photo_id));
drop policy if exists "removal: withdraw or dismiss" on public.removal_requests;
create policy "removal: withdraw or dismiss" on public.removal_requests
  for delete to authenticated using (requested_by = auth.uid() or private.can_manage_target(album_id, photo_id));
revoke update on public.removal_requests from authenticated, anon;

-- Opening an invite link. Works for anyone signed in who isn't blocked (even while waiting for approval),
-- so the admin can see who invited them. Seeing the photos still requires approval.
create or replace function public.redeem_share_link(link_token text)
returns json language plpgsql security definer set search_path = '' as $$
declare l public.share_links; me public.profiles; label text; sid uuid;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null then raise exception 'Sign in first'; end if;
  if me.status = 'blocked' then raise exception 'This account can''t use invite links'; end if;
  select * into l from public.share_links where token = link_token;
  if l.token is null or l.revoked or l.expires_at < now() then
    raise exception 'This invite link has expired or was turned off. Ask the person who sent it for a new one.';
  end if;
  if l.album_id is not null then
    select name into label from public.albums where id = l.album_id;
    if not exists (select 1 from public.albums where id = l.album_id and created_by = me.id) then
      insert into public.shares (album_id, member) values (l.album_id, me.id) on conflict do nothing returning id into sid;
    end if;
  else
    select file_name into label from public.photos where id = l.photo_id;
    if not exists (select 1 from public.photos where id = l.photo_id and uploader = me.id) then
      insert into public.shares (photo_id, member) values (l.photo_id, me.id) on conflict do nothing returning id into sid;
    end if;
  end if;
  -- credit the person who made the link (the insert above was stamped with whoever opened it)
  if sid is not null then update public.shares set created_by = l.created_by where id = sid; end if;
  return json_build_object('kind', case when l.album_id is not null then 'album' else 'photo' end,
                           'id', coalesce(l.album_id, l.photo_id), 'name', label, 'from', l.created_by_name);
end $$;

-- Approved members' names, for picking who to share with (no emails).
create or replace function public.list_members_for_sharing()
returns table (id uuid, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_approved() then raise exception 'Only approved members can share'; end if;
  return query select p.id, p.display_name from public.profiles p
               where p.status = 'approved' order by p.display_name;
end $$;

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
drop policy if exists "photos: delete allowed files" on storage.objects;
create policy "photos: delete allowed files" on storage.objects
  for delete to authenticated using (bucket_id = 'photos' and private.can_delete_file(name));

-- ============ Admin: member list ============
-- "invited_by" shows who sent an invite link to someone, to help decide whether to approve them.
drop function if exists public.admin_list_members();
create function public.admin_list_members()
returns table (id uuid, display_name text, email text, status text, is_admin boolean, is_moderator boolean, created_at timestamptz, invited_by text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_moderator() then raise exception 'Only admins and moderators can list members'; end if;
  return query select p.id, p.display_name, p.email, p.status, p.is_admin, p.is_moderator, p.created_at,
      (select string_agg(distinct inviter.display_name, ', ')
         from public.shares sh join public.profiles inviter on inviter.id = sh.created_by
        where sh.member = p.id)
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
revoke execute on function private.is_approved(), private.is_admin(), private.is_moderator(), private.can_see_album(uuid),
  private.can_manage_album(uuid), private.can_manage_photo(uuid), private.can_manage_target(uuid, uuid),
  private.can_view_photo(uuid, uuid, uuid, boolean), private.can_delete_photo(uuid),
  private.can_view_file(text), private.can_delete_file(text), private.is_approved_member(uuid),
  private.can_request_removal(uuid, uuid) from public, anon;
grant execute on function private.is_approved(), private.is_admin(), private.is_moderator(), private.can_see_album(uuid),
  private.can_manage_album(uuid), private.can_manage_photo(uuid), private.can_manage_target(uuid, uuid),
  private.can_view_photo(uuid, uuid, uuid, boolean), private.can_delete_photo(uuid),
  private.can_view_file(text), private.can_delete_file(text), private.is_approved_member(uuid),
  private.can_request_removal(uuid, uuid) to authenticated;
revoke execute on function public.handle_new_user(), public.stamp_photo(), public.stamp_album(),
  public.stamp_share(), public.stamp_share_link(), public.stamp_removal_request() from public, anon, authenticated; -- triggers only
revoke execute on function public.set_member_status(uuid, text), public.set_member_role(uuid, text), public.admin_list_members(),
  public.redeem_share_link(text), public.list_members_for_sharing() from public, anon;
grant execute on function public.set_member_status(uuid, text), public.set_member_role(uuid, text), public.admin_list_members(),
  public.redeem_share_link(text), public.list_members_for_sharing() to authenticated;

-- Helpers from earlier versions of this script that are no longer used.
drop function if exists public.is_approved();
drop function if exists public.is_admin();
drop function if exists private.can_use_album(uuid);
drop function if exists private.can_view_photo(uuid, uuid);
drop function if exists private.can_delete_photo(uuid, uuid);

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
-- Lets open pages hear about new, moved, shared or deleted photos and albums right away.
do $$
declare t text;
begin
  foreach t in array array['photos', 'albums', 'shares', 'removal_requests'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
