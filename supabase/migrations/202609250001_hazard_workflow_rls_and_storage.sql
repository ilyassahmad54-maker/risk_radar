-- RiskRadar hazard workflow policy fixes
-- Added after end-to-end Worker -> Contractor -> Safety Officer testing.

-- Allow a Safety Officer to read the site currently assigned to them.
drop policy if exists "sites_select_assigned_hse" on public.sites;

create policy "sites_select_assigned_hse"
on public.sites
for select
to authenticated
using (
  exists (
    select 1
    from public.hse_workers h
    where h.id = auth.uid()
      and h.current_site_id = sites.id
  )
);

-- Allow a Safety Officer to read workers assigned to the same site.
drop policy if exists "workers_select_same_site_hse" on public.workers;

create policy "workers_select_same_site_hse"
on public.workers
for select
to authenticated
using (
  exists (
    select 1
    from public.hse_workers h
    where h.id = auth.uid()
      and h.current_site_id is not null
      and h.current_site_id = workers.current_site_id
  )
);

-- Allow authenticated users to upload hazard evidence.
drop policy if exists "hazard_images_insert_authenticated"
on storage.objects;

create policy "hazard_images_insert_authenticated"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'hazard-images'
);

-- Allow authenticated users to upload resolution evidence.
drop policy if exists "resolutions_insert_authenticated"
on storage.objects;

create policy "resolutions_insert_authenticated"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'resolutions'
);
