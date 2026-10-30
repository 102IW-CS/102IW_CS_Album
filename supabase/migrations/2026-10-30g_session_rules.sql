-- Sign-in session rules, chosen by the admin. (No drops.)
-- idle_timeout_minutes: sign people out after this long without activity (null = never).
-- allow_remember: false = nobody can stay signed in after closing the browser.
-- The site enforces these in the browser. (Supabase's own server-side session limits
-- need a paid plan.) Visitors can read just these two columns, so the sign-in form
-- can hide "Keep me signed in" before anyone signs in.

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

-- Starting values the owner asked for: 15 minutes idle, and sign in again after closing the browser.
update public.album_settings set idle_timeout_minutes = 15, allow_remember = false
 where id = 1 and idle_timeout_minutes is null and allow_remember;
