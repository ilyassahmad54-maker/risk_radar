-- Secure SOS acknowledgement and restrict direct site_alert updates.
--
-- Recipients acknowledge alerts through a narrowly scoped SECURITY DEFINER RPC.
-- Direct UPDATE access is reserved for the original reporter.

create or replace function public.acknowledge_site_alert(p_alert_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  update public.site_alerts sa
  set
    acknowledged_at = now(),
    acknowledged_by = auth.uid()
  where sa.id = p_alert_id
    and sa.status = 'ACTIVE'
    and sa.reporter_uid <> auth.uid()
    and (
      exists (
        select 1
        from public.workers w
        where w.id = auth.uid()
          and w.current_site_id = sa.site_id
      )
      or exists (
        select 1
        from public.hse_workers h
        where h.id = auth.uid()
          and h.current_site_id = sa.site_id
      )
      or exists (
        select 1
        from public.sites s
        where s.id = sa.site_id
          and s.officer_uid = auth.uid()
      )
    );

  if not found then
    raise exception 'Alert not found or acknowledgement not permitted';
  end if;
end;
$$;

revoke all on function public.acknowledge_site_alert(uuid) from public;
grant execute on function public.acknowledge_site_alert(uuid) to authenticated;

drop policy if exists "site_alerts_update_site_members"
  on public.site_alerts;

drop policy if exists "site_alerts_update_own"
  on public.site_alerts;

create policy "site_alerts_update_own"
on public.site_alerts
for update
to authenticated
using (
  reporter_uid = auth.uid()
)
with check (
  reporter_uid = auth.uid()
);
