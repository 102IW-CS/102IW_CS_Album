-- Admins can remove a member's account entirely. (No drops.)
-- Deleting the sign-in account removes their member record (and with it anything shared with them
-- and their removal requests). Photos and albums they made stay, owned by nobody, so only admins can
-- manage them; the site can delete those first if the admin chooses (files must go through the
-- Storage API, so that part happens in the page). Invite links they created are turned off.

-- Invite-link guard: still freezes every field except "turned off", but lets the creator become
-- empty when their account is deleted (members can only update the "revoked" column anyway).
create or replace function public.guard_share_link_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.token := old.token; new.album_id := old.album_id; new.photo_id := old.photo_id;
  new.created_by := case when new.created_by is null then null else old.created_by end;
  new.created_by_name := old.created_by_name;
  new.created_at := old.created_at; new.expires_at := old.expires_at;
  new.revoked := old.revoked or new.revoked; -- a turned-off link stays off
  return new;
end $$;

create or replace function public.admin_remove_member(target uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Only admins can remove members'; end if;
  if target = auth.uid() then raise exception 'You can''t remove your own account'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'That member no longer exists'; end if;
  update public.share_links set revoked = true where created_by = target;
  delete from auth.users where id = target;
end $$;

revoke execute on function public.admin_remove_member(uuid) from public, anon;
grant execute on function public.admin_remove_member(uuid) to authenticated;
