-- Active assigned hazards read model used by worker/officer screens
-- and proximity notification monitoring.
--
-- security_invoker ensures underlying table RLS remains applicable.

create or replace view public.worker_active_hazards_view
with (security_invoker = true)
as
select
    a.*,

    -- Worker / hazard reporter
    w.first_name        as reporter_first_name,
    w.last_name         as reporter_last_name,
    w.work_type         as reporter_work_type,
    w.profile_image_url as reporter_image,

    -- Assigned Safety Officer / HSE worker
    h.first_name        as hse_first_name,
    h.last_name         as hse_last_name,
    h.designation       as hse_designation,
    h.profile_image_url as hse_image

from public.assign_hazards a

left join public.workers w
    on w.id = a.worker_id

left join public.hse_workers h
    on h.id = a.assigned_to

where lower(coalesce(a.status, '')) in (
    'assigned',
    'in_progress',
    'in progress'
);
