create table if not exists public.hazard_notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  hazard_id uuid not null,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  notification_type text not null
    check (notification_type in ('worker_proximity')),
  created_at timestamptz not null default now(),
  unique (hazard_id, recipient_id, notification_type)
);

create index if not exists idx_hazard_notification_deliveries_recipient
  on public.hazard_notification_deliveries(recipient_id, created_at desc);

alter table public.hazard_notification_deliveries enable row level security;

comment on table public.hazard_notification_deliveries is
  'Server-only idempotency log that prevents duplicate hazard pushes.';
