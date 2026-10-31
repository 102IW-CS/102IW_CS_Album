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

-- Only "turn off" can change on a link; everything else stays as created.
create or replace function public.guard_share_link_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.token := old.token; new.album_id := old.album_id; new.photo_id := old.photo_id;
  -- the creator may only become empty, when their account is deleted
  new.created_by := case when new.created_by is null then null else old.created_by end;
  new.created_by_name := old.created_by_name;
  new.created_at := old.created_at; new.expires_at := old.expires_at;
  new.revoked := old.revoked or new.revoked; -- a turned-off link stays off
  return new;
end $$;
drop trigger if exists guard_share_link_update on public.share_links;
create trigger guard_share_link_update before update on public.share_links
  for each row execute function public.guard_share_link_update();

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
-- Checks the row's own fields: creating an album returns the new row, and a lookup by id
-- can't see a row inserted in the same statement.
create policy "albums: see own, shared, or all if admin" on public.albums
  for select to authenticated
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid() or shared
         or exists (select 1 from public.shares s where s.album_id = albums.id and s.member = auth.uid())));

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
drop function if exists public.list_members_admin(); -- older name
create or replace function public.list_members_admin()
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

-- ============ Contact inbox ============
-- Messages from the public contact page. Anyone (signed in or not) can send one;
-- only admins can read, mark or delete them. Validation and a flood limit run on the server.
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
  perform private.purge_read_messages(); -- inbox auto-delete (defined with album settings below)
  return new;
end $$;
drop trigger if exists stamp_contact_message on public.contact_messages;
create trigger stamp_contact_message before insert on public.contact_messages
  for each row execute function public.stamp_contact_message();

drop policy if exists "contact: anyone can send" on public.contact_messages;
create policy "contact: anyone can send" on public.contact_messages
  for insert to anon, authenticated with check (true);
drop policy if exists "contact: admins read" on public.contact_messages;
create policy "contact: admins read" on public.contact_messages
  for select to authenticated using (private.is_admin());
drop policy if exists "contact: admins mark read" on public.contact_messages;
create policy "contact: admins mark read" on public.contact_messages
  for update to authenticated using (private.is_admin()) with check (private.is_admin());
drop policy if exists "contact: admins delete" on public.contact_messages;
create policy "contact: admins delete" on public.contact_messages
  for delete to authenticated using (private.is_admin());

revoke all on public.contact_messages from anon, authenticated;
grant insert (name, email, phone, topic, message) on public.contact_messages to anon, authenticated;
grant select, delete on public.contact_messages to authenticated;
grant update (read) on public.contact_messages to authenticated;

-- ============ Admin: remove a member ============
-- Deletes the sign-in account; the member record (and shares to them, their removal requests)
-- go with it. Their photos and albums stay, owned by nobody, so only admins can manage them;
-- the page deletes those first if the admin chooses. Invite links they made are turned off.
create or replace function public.admin_remove_member(target uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can remove members'; end if;
  if target = auth.uid() then raise exception 'You can''t remove your own account'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'That member no longer exists'; end if;
  update public.share_links set revoked = true where created_by = target;
  delete from auth.users where id = target;
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

-- Inbox auto-delete: the admin chooses how long to keep READ contact messages (unread are never auto-deleted).
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

-- Sign-in session rules (enforced by the site in each browser): sign out after N idle minutes,
-- and whether "Keep me signed in" is allowed. Visitors may read just these two columns.
alter table public.album_settings add column if not exists idle_timeout_minutes int
  constraint album_settings_idle_timeout_check check (idle_timeout_minutes in (5, 10, 15, 30, 60, 240));
alter table public.album_settings add column if not exists allow_remember boolean not null default true;
grant update (idle_timeout_minutes, allow_remember) on public.album_settings to authenticated;

grant select (id, idle_timeout_minutes, allow_remember) on public.album_settings to anon;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'album_settings' and policyname = 'visitors read sign-in rules') then
    create policy "visitors read sign-in rules" on public.album_settings for select to anon using (true);
  end if;
end $$;

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
  public.stamp_share(), public.stamp_share_link(), public.guard_share_link_update(), public.stamp_removal_request(),
  public.stamp_contact_message() from public, anon, authenticated; -- triggers only
revoke execute on function public.set_member_status(uuid, text), public.set_member_role(uuid, text), public.list_members_admin(), public.admin_remove_member(uuid),
  public.redeem_share_link(text), public.list_members_for_sharing() from public, anon;
grant execute on function public.set_member_status(uuid, text), public.set_member_role(uuid, text), public.list_members_admin(), public.admin_remove_member(uuid),
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
  foreach t in array array['photos', 'albums', 'shares', 'removal_requests', 'contact_messages'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ============ My account ============
-- Change your display name everywhere it was copied (photos, albums, removal requests).
-- Invite links keep the name they were made with (they expire after 30 days).
create or replace function public.rename_me(new_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); n text := left(trim(new_name), 60);
begin
  if me is null then raise exception 'Sign in first'; end if;
  if n is null or n = '' then raise exception 'Enter your name'; end if;
  update public.profiles set display_name = n where id = me;
  update public.photos set uploader_name = n where uploader = me;
  update public.albums set created_by_name = n where created_by = me;
  update public.removal_requests set requested_by_name = n where requested_by = me;
  return n;
end $$;
revoke execute on function public.rename_me(text) from public, anon;
grant execute on function public.rename_me(text) to authenticated;

-- Delete your own account. The page deletes your photo files first (files must go through the
-- Storage API); this removes the sign-in, which also removes your member record, shares and
-- removal requests. The last admin can't delete themselves, so the album always has an admin.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first'; end if;
  if exists (select 1 from public.profiles where id = me and is_admin)
     and (select count(*) from public.profiles where is_admin and status = 'approved') <= 1 then
    raise exception 'You are the only admin. Make someone else an admin first.';
  end if;
  update public.share_links set revoked = true where created_by = me;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- Member list plus which Terms version each person accepted, and when (from their account record).
create or replace function public.list_members_with_terms()
returns table (id uuid, display_name text, email text, status text, is_admin boolean, is_moderator boolean,
               created_at timestamptz, invited_by text, terms_version text, terms_accepted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_moderator() then raise exception 'Only admins and moderators can list members'; end if;
  return query select p.id, p.display_name, p.email, p.status, p.is_admin, p.is_moderator, p.created_at,
      (select string_agg(distinct inviter.display_name, ', ')
         from public.shares sh join public.profiles inviter on inviter.id = sh.created_by
        where sh.member = p.id),
      u.raw_user_meta_data ->> 'terms_version',
      case when (u.raw_user_meta_data ->> 'terms_accepted_at') ~ '^\d{4}-\d{2}-\d{2}T'
           then (u.raw_user_meta_data ->> 'terms_accepted_at')::timestamptz end
    from public.profiles p left join auth.users u on u.id = p.id
   order by (p.status = 'pending') desc, p.created_at desc;
end $$;
revoke execute on function public.list_members_with_terms() from public, anon;
grant execute on function public.list_members_with_terms() to authenticated;

-- ============ Real email addresses ============
-- Throwaway domains refused at sign-up; approval requires a confirmed email; who has confirmed.
-- (These replace the earlier handle_new_user and set_member_status definitions above.)
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

-- ============ Automatic approval (optional) ============
-- When an admin turns it on, a pending account is approved the moment its email is confirmed
-- (optionally only for listed email domains). Off by default.
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

-- ====================================================================
-- Added Oct 30, 2026: private messages, member search, unsend, sign-in pictures, rotation speed
-- (same as the files in supabase/migrations with these names)
-- ====================================================================

-- ---- 2026-10-30k_messages.sql ----
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

-- ---- 2026-10-30q_messages_cleanup.sql ----
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

-- ---- 2026-10-30l_member_search.sql ----
-- Member search for Messages: by name or email, best matches first. (No drops, no deletes.)
-- Full email addresses are never returned to members: only a short hint like "b•••@gmail.com".
-- Matching on email needs at least 3 characters, so addresses can't be guessed letter by letter.

create or replace function private.mask_email(e text)
returns text language sql immutable set search_path = '' as $$
  select case when e is null or position('@' in e) = 0 then null
              else left(split_part(e, '@', 1), 1) || '•••@' || split_part(e, '@', 2) end;
$$;

-- Lowercase and drop common accents, so "ange" finds "Ángela".
create or replace function private.fold(x text)
returns text language sql immutable set search_path = '' as $$
  select translate(lower(coalesce(x, '')), 'áàâäãåāçčéèêëēěíìîïīñńóòôöõøōúùûüūůýÿžšř', 'aaaaaaacceeeeeeiiiiinnoooooooouuuuuuyyzsr');
$$;

create or replace function public.search_members(q text default '')
returns table (id uuid, display_name text, email_hint text, matched text)
language plpgsql stable security definer set search_path = '' as $$
declare
  t text := private.fold(trim(coalesce(q, '')));
  e text := replace(replace(replace(private.fold(trim(coalesce(q, ''))), '\', '\\'), '%', '\%'), '_', '\_'); -- typed text, LIKE-safe
begin
  if not private.is_approved() then raise exception 'Only approved members can search for people'; end if;
  return query
  select p.id, p.display_name, private.mask_email(p.email),
         case when t = '' then null
              when private.fold(p.display_name) like '%' || e || '%' then 'name'
              else 'email' end
    from public.profiles p
   where p.status = 'approved' and p.id <> auth.uid()
     and (t = '' or private.fold(p.display_name) like '%' || e || '%'
          or (char_length(t) >= 3 and lower(p.email) like '%' || e || '%'))
   order by case when t = '' then 0
                 when private.fold(p.display_name) like e || '%' then 0                 -- name starts with it
                 when private.fold(p.display_name) like '% ' || e || '%' then 1         -- a later word starts with it
                 when lower(split_part(p.email, '@', 1)) like e || '%' then 2    -- email starts with it
                 when private.fold(p.display_name) like '%' || e || '%' then 3          -- name contains it
                 else 4 end,                                                     -- email contains it
            private.fold(p.display_name)
   limit 200;
end $$;

revoke execute on function private.mask_email(text), private.fold(text) from public, anon;
grant execute on function private.fold(text) to authenticated;
grant execute on function private.mask_email(text) to authenticated;
revoke execute on function public.search_members(text) from public, anon;
grant execute on function public.search_members(text) to authenticated;

-- ---- 2026-10-30m_unsend_messages.sql ----
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

-- ---- 2026-10-30o_signin_pictures.sql ----
-- Sign-in pictures. (No drops, no deletes.)
-- Admins pick the pictures shown on the sign-in page. They are public on purpose: people see them
-- before signing in. They live in their own bucket ("site"), apart from members' private photos.

create table if not exists public.site_pictures (
  id         uuid primary key default gen_random_uuid(),
  path       text not null unique check (path ~ '^signin/[A-Za-z0-9._-]{1,120}$'),
  caption    text check (char_length(caption) <= 60),
  credit     text check (char_length(credit) <= 120),
  credit_url text check (credit_url is null or (char_length(credit_url) <= 300 and credit_url ~ '^https://[^[:space:]"<>]+$')),
  width      int check (width between 1 and 20000),
  height     int check (height between 1 and 20000),
  shown      boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.site_pictures enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_pictures' and policyname = 'site pictures: everyone sees shown ones') then
    create policy "site pictures: everyone sees shown ones" on public.site_pictures for select to anon, authenticated
      using (shown or private.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_pictures' and policyname = 'site pictures: admins add') then
    create policy "site pictures: admins add" on public.site_pictures for insert to authenticated with check (private.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_pictures' and policyname = 'site pictures: admins edit') then
    create policy "site pictures: admins edit" on public.site_pictures for update to authenticated
      using (private.is_admin()) with check (private.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'site_pictures' and policyname = 'site pictures: admins remove') then
    create policy "site pictures: admins remove" on public.site_pictures for delete to authenticated using (private.is_admin());
  end if;
end $$;

revoke all on public.site_pictures from anon, authenticated;
-- Visitors read only what the page needs (not who added each picture).
grant select (id, path, caption, credit, credit_url, width, height, shown, created_at) on public.site_pictures to anon, authenticated;
grant insert (path, caption, credit, credit_url, width, height, shown) on public.site_pictures to authenticated;
grant update (caption, credit, credit_url, shown) on public.site_pictures to authenticated;
grant delete on public.site_pictures to authenticated;
grant usage on schema private to anon;
grant execute on function private.is_admin() to anon;

-- Who added it and when are set by the database; at most 40 pictures.
create or replace function public.stamp_site_picture()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_by := auth.uid();
  new.created_at := now();
  if (select count(*) from public.site_pictures) >= 40 then
    raise exception 'You can keep up to 40 sign-in pictures. Remove some first.';
  end if;
  return new;
end $$;
revoke execute on function public.stamp_site_picture() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'site_pictures_stamp') then
    create trigger site_pictures_stamp before insert on public.site_pictures for each row execute function public.stamp_site_picture();
  end if;
end $$;

-- Public bucket: anyone can view a file by its address; only admins can add or remove files.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site', 'site', true, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'site: admins see files') then
    create policy "site: admins see files" on storage.objects for select to authenticated
      using (bucket_id = 'site' and private.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'site: admins add files') then
    create policy "site: admins add files" on storage.objects for insert to authenticated
      with check (bucket_id = 'site' and private.is_admin() and name ~ '^signin/[A-Za-z0-9._-]{1,120}$');
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'site: admins remove files') then
    create policy "site: admins remove files" on storage.objects for delete to authenticated
      using (bucket_id = 'site' and private.is_admin());
  end if;
end $$;

-- ---- 2026-10-30p_signin_speed.sql ----
-- Sign-in pictures: how often a card changes (seconds). 0 = don't rotate. (No drops, no deletes.)
alter table public.album_settings add column if not exists signin_turn_seconds int not null default 8;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'album_settings_signin_turn_seconds_check') then
    alter table public.album_settings add constraint album_settings_signin_turn_seconds_check
      check (signin_turn_seconds = 0 or signin_turn_seconds between 3 and 120);
  end if;
end $$;
grant select (signin_turn_seconds) on public.album_settings to anon, authenticated;  -- the sign-in page needs it
grant update (signin_turn_seconds) on public.album_settings to authenticated;         -- admins only, by policy
