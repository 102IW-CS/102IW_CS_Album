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
