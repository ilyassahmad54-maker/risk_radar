-- RiskRadar SOS schema + site-scoped RLS
-- Aligns site_alerts with the Flutter SOS sender and FCM acknowledgement flow.

-- ============================================================
-- 1. Add fields required by the current SOS implementation
-- ============================================================

alter table public.site_alerts
  add column if not exists site_id uuid
    references public.sites(id) on delete cascade,
  add column if not exists role text,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists status text not null default 'ACTIVE';

create index if not exists idx_site_alerts_site_id
  on public.site_alerts(site_id);

create index if not exists idx_site_alerts_site_created_at
  on public.site_alerts(site_id, created_at desc);


-- ============================================================
-- 2. Remove the old reporter-only RLS policies
-- ============================================================

drop policy if exists "site_alerts_select_own"
  on public.site_alerts;

drop policy if exists "site_alerts_insert_own"
  on public.site_alerts;

drop policy if exists "site_alerts_update_own"
  on public.site_alerts;

drop policy if exists "site_alerts_delete_own"
  on public.site_alerts;


-- ============================================================
-- 3. Reporter can create an SOS only for a site that belongs
--    to their contractor/site scope.
-- ============================================================

create policy "site_alerts_insert_scoped"
on public.site_alerts
for insert
to authenticated
with check (
  reporter_uid = auth.uid()
  and site_id is not null
  and (
    -- Worker assigned to this site
    exists (
      select 1
      from public.workers w
      where w.id = auth.uid()
        and w.current_site_id = site_alerts.site_id
        and w.officer_uid = (
          select s.officer_uid
          from public.sites s
          where s.id = site_alerts.site_id
        )
    )

    or

    -- Safety Officer assigned to this site
    exists (
      select 1
      from public.hse_workers h
      where h.id = auth.uid()
        and h.current_site_id = site_alerts.site_id
        and h.officer_uid = (
          select s.officer_uid
          from public.sites s
          where s.id = site_alerts.site_id
        )
    )

    or

    -- Contractor owns this site
    exists (
      select 1
      from public.sites s
      where s.id = site_alerts.site_id
        and s.officer_uid = auth.uid()
    )
  )
);


-- ============================================================
-- 4. Members of the same site and its contractor can read SOS
-- ============================================================

create policy "site_alerts_select_site_members"
on public.site_alerts
for select
to authenticated
using (
  reporter_uid = auth.uid()

  or exists (
    select 1
    from public.workers w
    where w.id = auth.uid()
      and w.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.hse_workers h
    where h.id = auth.uid()
      and h.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.sites s
    where s.id = site_alerts.site_id
      and s.officer_uid = auth.uid()
  )
);


-- ============================================================
-- 5. Same-site recipients may acknowledge an SOS.
--    This is required by SosAcknowledgeScreen.
-- ============================================================

create policy "site_alerts_update_site_members"
on public.site_alerts
for update
to authenticated
using (
  reporter_uid = auth.uid()

  or exists (
    select 1
    from public.workers w
    where w.id = auth.uid()
      and w.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.hse_workers h
    where h.id = auth.uid()
      and h.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.sites s
    where s.id = site_alerts.site_id
      and s.officer_uid = auth.uid()
  )
)
with check (
  reporter_uid = auth.uid()

  or exists (
    select 1
    from public.workers w
    where w.id = auth.uid()
      and w.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.hse_workers h
    where h.id = auth.uid()
      and h.current_site_id = site_alerts.site_id
  )

  or exists (
    select 1
    from public.sites s
    where s.id = site_alerts.site_id
      and s.officer_uid = auth.uid()
  )
);


-- ============================================================
-- 6. Only the original reporter may delete their SOS record
-- ============================================================

create policy "site_alerts_delete_own"
on public.site_alerts
for delete
to authenticated
using (
  reporter_uid = auth.uid()
);
