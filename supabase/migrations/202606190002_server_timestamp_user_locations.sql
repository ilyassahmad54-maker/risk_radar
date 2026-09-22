create table if not exists public.user_locations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  latitude double precision not null,
  longitude double precision not null,
  updated_at timestamptz not null default statement_timestamp()
);

alter table public.user_locations enable row level security;

create policy "user_locations_select_own"
  on public.user_locations
  for select
  to authenticated
  using (user_id = auth.uid());

create policy "user_locations_insert_own"
  on public.user_locations
  for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "user_locations_update_own"
  on public.user_locations
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.set_user_location_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = statement_timestamp();
  return new;
end;
$$;

drop trigger if exists set_user_location_updated_at
  on public.user_locations;

create trigger set_user_location_updated_at
before insert or update on public.user_locations
for each row
execute function public.set_user_location_updated_at();

update public.user_locations
set updated_at = statement_timestamp()
where updated_at > statement_timestamp();
