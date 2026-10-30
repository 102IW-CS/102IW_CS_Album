-- Upgrade from the "private + admin-shared albums" version to sharing, invite links,
-- removal requests and roles — without dropping anything, so it can run without a
-- confirmation prompt (for example from a phone). Existing rules are edited in place.
-- On a desktop, running all of supabase/setup.sql does the same and also tidies up.

-- ---------- roles ----------
alter table public.profiles add column if not exists is_moderator boolean not null default false;

create or replace function private.is_moderator()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and status = 'approved' and (is_admin or is_moderator));
$$;

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

-- ---------- photos & albums ----------
alter table public.photos add column if not exists shared boolean not null default false;
grant update (album_id, shared) on public.photos to authenticated;

create or replace function public.stamp_album()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.created_by := auth.uid();
  new.created_by_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  new.shared := coalesce(new.shared, false);
  return new;
end $$;

-- Album creators may now change sharing too: turn the old admin-only check into a no-op.
create or replace function public.guard_album_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  return new;
end $$;

-- ---------- sharing with specific members ----------
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
create trigger stamp_share before insert on public.shares for each row execute function public.stamp_share();

-- ---------- invite links ----------
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
  new.token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  new.created_by := auth.uid();
  new.created_by_name := (select display_name from public.profiles where id = auth.uid());
  new.created_at := now();
  new.expires_at := now() + interval '30 days';
  new.revoked := false;
  return new;
end $$;
create trigger stamp_share_link before insert on public.share_links for each row execute function public.stamp_share_link();

-- Only "turn off" can change on a link; everything else stays as created.
create or replace function public.guard_share_link_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.token := old.token; new.album_id := old.album_id; new.photo_id := old.photo_id;
  new.created_by := old.created_by; new.created_by_name := old.created_by_name;
  new.created_at := old.created_at; new.expires_at := old.expires_at;
  new.revoked := old.revoked or new.revoked; -- a turned-off link stays off
  return new;
end $$;
create trigger guard_share_link_update before update on public.share_links for each row execute function public.guard_share_link_update();

-- ---------- visibility helpers ----------
create or replace function private.can_see_album(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.albums a
    where a.id = target and (private.is_admin() or a.created_by = auth.uid() or a.shared
      or exists (select 1 from public.shares s where s.album_id = a.id and s.member = auth.uid())));
$$;
create or replace function private.can_manage_album(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.albums a where a.id = target and (private.is_admin() or a.created_by = auth.uid()));
$$;
create or replace function private.can_manage_photo(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and exists (
    select 1 from public.photos p where p.id = target and (private.is_admin() or p.uploader = auth.uid()));
$$;
create or replace function private.can_manage_target(album uuid, photo uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when album is not null then private.can_manage_album(album) else private.can_manage_photo(photo) end;
$$;
create or replace function private.can_view_photo(photo uuid, photo_owner uuid, photo_album uuid, photo_shared boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin() or photo_owner = auth.uid() or photo_shared
    or exists (select 1 from public.shares s where s.photo_id = photo and s.member = auth.uid())
    or (photo_album is not null and private.can_see_album(photo_album)));
$$;
create or replace function private.can_delete_photo(photo_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (private.is_admin() or photo_owner = auth.uid());
$$;
create or replace function private.can_view_file(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (
    private.is_admin() or split_part(object_name, '/', 1) = auth.uid()::text
    or exists (select 1 from public.photos p
               where (p.path = object_name or p.thumb_path = object_name)
                 and private.can_view_photo(p.id, p.uploader, p.album_id, p.shared)));
$$;
create or replace function private.can_delete_file(object_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_approved() and (private.is_admin() or split_part(object_name, '/', 1) = auth.uid()::text);
$$;
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
grant execute on function private.is_moderator(), private.can_see_album(uuid), private.can_manage_album(uuid),
  private.can_manage_photo(uuid), private.can_manage_target(uuid, uuid), private.can_view_photo(uuid, uuid, uuid, boolean),
  private.can_delete_photo(uuid), private.can_delete_file(text), private.can_request_removal(uuid, uuid),
  private.is_approved_member(uuid) to authenticated;

-- ---------- existing rules, edited in place ----------
alter policy "photos: see own, shared, or all if admin" on public.photos
  using (private.can_view_photo(id, uploader, album_id, shared));
alter policy "photos: add own into usable album" on public.photos
  with check (private.is_approved() and split_part(path, '/', 1) = auth.uid()::text
              and (album_id is null or private.can_see_album(album_id)));
alter policy "photos: move own" on public.photos
  using (private.is_approved() and (uploader = auth.uid() or private.is_admin()))
  with check (private.is_approved() and (uploader = auth.uid() or private.is_admin())
              and (album_id is null or private.can_see_album(album_id)));
alter policy "photos: delete what you can see" on public.photos   -- now: only the uploader or an admin
  using (private.can_delete_photo(uploader));

alter policy "albums: see own, shared, or all if admin" on public.albums
  using (private.can_see_album(id));
alter policy "albums: owner or admin can edit" on public.albums
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid()))
  with check (private.is_approved() and (private.is_admin() or created_by = auth.uid()));
alter policy "albums: owner or admin can delete" on public.albums
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid()));

alter policy "photos: delete visible files" on storage.objects     -- now: own folder or admin
  using (bucket_id = 'photos' and private.can_delete_file(name));

-- ---------- rules for the new tables ----------
create policy "shares: see own or managed" on public.shares
  for select to authenticated using (member = auth.uid() or private.can_manage_target(album_id, photo_id));
create policy "shares: add for managed items" on public.shares
  for insert to authenticated
  with check (private.can_manage_target(album_id, photo_id) and member <> auth.uid() and private.is_approved_member(member));
create policy "shares: remove managed or own" on public.shares
  for delete to authenticated using (member = auth.uid() or private.can_manage_target(album_id, photo_id));

create policy "links: see managed" on public.share_links
  for select to authenticated using (private.can_manage_target(album_id, photo_id));
create policy "links: create for managed" on public.share_links
  for insert to authenticated with check (private.can_manage_target(album_id, photo_id));
create policy "links: turn off managed" on public.share_links
  for update to authenticated
  using (private.can_manage_target(album_id, photo_id)) with check (private.can_manage_target(album_id, photo_id));
create policy "links: delete managed" on public.share_links
  for delete to authenticated using (private.can_manage_target(album_id, photo_id));

-- ---------- removal requests ----------
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
create trigger stamp_removal_request before insert on public.removal_requests for each row execute function public.stamp_removal_request();
create policy "removal: see own or managed" on public.removal_requests
  for select to authenticated using (requested_by = auth.uid() or private.can_manage_target(album_id, photo_id));
create policy "removal: ask" on public.removal_requests
  for insert to authenticated with check (private.can_request_removal(album_id, photo_id));
create policy "removal: withdraw or dismiss" on public.removal_requests
  for delete to authenticated using (requested_by = auth.uid() or private.can_manage_target(album_id, photo_id));

-- ---------- functions the page calls ----------
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
  if sid is not null then update public.shares set created_by = l.created_by where id = sid; end if;
  return json_build_object('kind', case when l.album_id is not null then 'album' else 'photo' end,
                           'id', coalesce(l.album_id, l.photo_id), 'name', label, 'from', l.created_by_name);
end $$;

create or replace function public.list_members_for_sharing()
returns table (id uuid, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_approved() then raise exception 'Only approved members can share'; end if;
  return query select p.id, p.display_name from public.profiles p where p.status = 'approved' order by p.display_name;
end $$;

-- New name, because the old admin_list_members can't change its columns without being dropped.
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

grant execute on function public.set_member_role(uuid, text), public.redeem_share_link(text),
  public.list_members_for_sharing(), public.list_members_admin() to authenticated;

-- ---------- live updates ----------
alter publication supabase_realtime add table public.shares;
alter publication supabase_realtime add table public.removal_requests;
