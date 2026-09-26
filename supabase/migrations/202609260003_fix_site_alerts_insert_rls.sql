-- RiskRadar SOS insert RLS fix
-- Avoids nested RLS visibility problems when workers/HSE personnel
-- create site_alerts for their assigned site.

create or replace function public.can_send_site_alert(p_site_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select
    auth.uid() is not null
    and p_site_id is not null
    and (
      exists (
        select 1
        from public.workers w
        where w.id = auth.uid()
          and w.current_site_id = p_site_id
          and w.officer_uid = (
            select s.officer_uid
            from public.sites s
            where s.id = p_site_id
          )
      )
      or exists (
        select 1
        from public.hse_workers h
        where h.id = auth.uid()
          and h.current_site_id = p_site_id
          and h.officer_uid = (
            select s.officer_uid
            from public.sites s
            where s.id = p_site_id
          )
      )
      or exists (
        select 1
        from public.sites s
        where s.id = p_site_id
          and s.officer_uid = auth.uid()
      )
    );
$$;

revoke all on function public.can_send_site_alert(uuid) from public;
grant execute on function public.can_send_site_alert(uuid) to authenticated;

drop policy if exists "site_alerts_insert_scoped"
  on public.site_alerts;

create policy "site_alerts_insert_scoped"
on public.site_alerts
for insert
to authenticated
with check (
  reporter_uid = auth.uid()
  and site_id is not null
  and public.can_send_site_alert(site_id)
);
