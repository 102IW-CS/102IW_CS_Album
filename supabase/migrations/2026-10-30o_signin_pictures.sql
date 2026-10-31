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
