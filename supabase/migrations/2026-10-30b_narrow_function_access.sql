-- Follow-up to 2026-10-30_sharing_no_drops.sql: narrow who may run the new functions
-- (Postgres lets everyone run new functions by default). Permission-only; nothing is dropped.
revoke execute on function public.stamp_share(), public.stamp_share_link(), public.guard_share_link_update(),
  public.stamp_removal_request(), public.guard_album_update() from public, anon, authenticated;
revoke execute on function public.set_member_role(uuid, text), public.redeem_share_link(text),
  public.list_members_for_sharing(), public.list_members_admin(), public.admin_list_members() from public, anon;
revoke execute on function public.admin_list_members() from authenticated;
revoke execute on function private.is_moderator(), private.can_see_album(uuid), private.can_manage_album(uuid),
  private.can_manage_photo(uuid), private.can_manage_target(uuid, uuid), private.can_view_photo(uuid, uuid, uuid, boolean),
  private.can_delete_photo(uuid), private.can_delete_file(text), private.can_request_removal(uuid, uuid),
  private.is_approved_member(uuid) from public, anon;
revoke update on public.shares, public.removal_requests from authenticated, anon;
revoke update on public.share_links from authenticated, anon;
grant update (revoked) on public.share_links to authenticated;
