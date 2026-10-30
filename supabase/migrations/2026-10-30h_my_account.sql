-- My account: rename yourself, delete your own account; admins see who accepted the Terms. (No drops.)

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
