-- Secure SOS cancellation.
--
-- The original reporter can cancel an ACTIVE SOS only through this
-- narrowly scoped SECURITY DEFINER RPC. Direct UPDATE access to
-- site_alerts is removed.

create or replace function public.cancel_site_alert(p_alert_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  update public.site_alerts
  set status = 'CANCELLED'
  where id = p_alert_id
    and reporter_uid = auth.uid()
    and status = 'ACTIVE';

  if not found then
    raise exception 'Alert not found or cancellation not permitted';
  end if;
end;
$$;

revoke all on function public.cancel_site_alert(uuid) from public;
grant execute on function public.cancel_site_alert(uuid) to authenticated;

drop policy if exists "site_alerts_update_site_members"
  on public.site_alerts;

drop policy if exists "site_alerts_update_own"
  on public.site_alerts;
