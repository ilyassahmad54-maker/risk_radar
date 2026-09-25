-- ============================================================
-- RiskRadar
-- Worker site context RPC
--
-- Provides the authenticated worker with their contractor,
-- current site, and assigned safety officers without requiring
-- recursive cross-table RLS policies.
-- ============================================================

create or replace function public.get_my_worker_site_context()
returns table (
  site_id uuid,
  site_name text,
  officer_uid uuid,
  contractor_name text,
  safety_officers text[]
)
language sql
security definer
set search_path = public
stable
as $$
  select
    w.current_site_id,
    s.name,
    w.officer_uid,
    nullif(
      trim(concat_ws(' ', o.first_name, o.last_name)),
      ''
    ) as contractor_name,
    coalesce(
      array_agg(
        distinct nullif(
          trim(concat_ws(' ', h.first_name, h.last_name)),
          ''
        )
      ) filter (
        where h.id is not null
          and h.is_active = true
      ),
      array[]::text[]
    ) as safety_officers
  from public.workers w
  left join public.sites s
    on s.id = w.current_site_id
   and s.officer_uid = w.officer_uid
  left join public.officers o
    on o.id = w.officer_uid
  left join public.hse_workers h
    on h.current_site_id = w.current_site_id
   and h.officer_uid = w.officer_uid
  where w.id = auth.uid()
  group by
    w.current_site_id,
    s.name,
    w.officer_uid,
    o.first_name,
    o.last_name;
$$;

revoke all
on function public.get_my_worker_site_context()
from public;

grant execute
on function public.get_my_worker_site_context()
to authenticated;
