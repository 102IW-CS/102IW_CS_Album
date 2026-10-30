-- Fix: creating an album failed because the visibility rule looked the new row up by id.
-- Check the row's own fields instead. (No drops.)
alter policy "albums: see own, shared, or all if admin" on public.albums
  using (private.is_approved() and (private.is_admin() or created_by = auth.uid() or shared
         or exists (select 1 from public.shares s where s.album_id = albums.id and s.member = auth.uid())));
