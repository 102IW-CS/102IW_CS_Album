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
