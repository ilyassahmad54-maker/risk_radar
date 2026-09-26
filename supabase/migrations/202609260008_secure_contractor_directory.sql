-- Secure contractor directory access.
--
-- Authenticated users need a limited contractor directory during
-- Worker / Safety Officer profile setup. Direct broad SELECT access
-- to the officers table is removed. The directory exposes only the
-- fields required by the profile setup UI.

create or replace function public.get_contractor_directory()
returns table (
  id uuid,
  first_name text,
  last_name text,
  email text
)
language sql
security definer
stable
set search_path = public
as $$
  select
    o.id,
    o.first_name,
    o.last_name,
    o.email
  from public.officers o
  where auth.uid() is not null
  order by o.first_name, o.last_name;
$$;

revoke all on function public.get_contractor_directory() from public;
revoke all on function public.get_contractor_directory() from anon;
grant execute on function public.get_contractor_directory() to authenticated;

drop policy if exists "officers_select_authenticated"
on public.officers;

drop policy if exists "officers_select_own"
on public.officers;

create policy "officers_select_own"
on public.officers
for select
to authenticated
using (
  id = auth.uid()
  or officer_uid = auth.uid()
);
