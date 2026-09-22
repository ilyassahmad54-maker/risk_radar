
create table if not exists public.officers (
  id uuid primary key default gen_random_uuid(),
  first_name text,
  last_name text,
  email text,
  role text default 'officer',
  officer_uid uuid,
  profile_image_url text,
  fcm_token text,
  dob date,
  created_at timestamptz not null default now()
);

create table if not exists public.sites (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  officer_uid uuid not null references public.officers(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.workers (
  id uuid primary key default gen_random_uuid(),
  first_name text,
  last_name text,
  email text,
  role text default 'worker',
  officer_uid uuid references public.officers(id) on delete set null,
  work_type text,
  profile_image_url text,
  is_active boolean not null default true,
  default_site_id uuid references public.sites(id) on delete set null,
  current_site_id uuid references public.sites(id) on delete set null,
  fcm_token text,
  created_at timestamptz not null default now()
);

create table if not exists public.hse_workers (
  id uuid primary key default gen_random_uuid(),
  first_name text,
  last_name text,
  email text,
  role text default 'hse_worker',
  officer_uid uuid references public.officers(id) on delete set null,
  designation text,
  profile_image_url text,
  is_active boolean not null default true,
  is_available boolean not null default true,
  current_site_id uuid references public.sites(id) on delete set null,
  fcm_token text,
  created_at timestamptz not null default now()
);

create table if not exists public.hazards (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid references public.workers(id) on delete set null,
  hazard_type text not null,
  description text,
  severity text not null check (severity in ('Critical', 'High', 'Medium', 'Low')),
  latitude double precision not null,
  longitude double precision not null,
  status text not null default 'reported' check (status in ('reported', 'assigned', 'in_progress', 'resolved', 'resolved by other')),
  created_at timestamptz not null default now(),
  image_url text,
  voice_note_url text,
  officer_uid uuid references public.officers(id) on delete set null,
  current_site_id uuid references public.sites(id) on delete set null,
  orphaned boolean not null default false,
  resolved_at timestamptz,
  ranking_score double precision,
  assigned_to uuid references public.hse_workers(id) on delete set null
);

create table if not exists public.assign_hazards (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid references public.workers(id) on delete set null,
  hazard_type text not null,
  description text,
  severity text not null check (severity in ('Critical', 'High', 'Medium', 'Low')),
  latitude double precision not null,
  longitude double precision not null,
  status text not null default 'assigned' check (status in ('reported', 'assigned', 'in_progress', 'resolved', 'resolved by other')),
  created_at timestamptz not null default now(),
  image_url text,
  voice_note_url text,
  officer_uid uuid references public.officers(id) on delete set null,
  current_site_id uuid references public.sites(id) on delete set null,
  orphaned boolean not null default false,
  resolved_at timestamptz,
  ranking_score double precision,
  assigned_to uuid references public.hse_workers(id) on delete set null,
  assigned_at timestamptz,
  started_at timestamptz,
  resolution_notes text,
  resolution_image_url text,
  resolution_voice_note_url text,
  report_number text
);

create table if not exists public.resolved_hazards (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid references public.workers(id) on delete set null,
  hazard_type text not null,
  description text,
  severity text not null check (severity in ('Critical', 'High', 'Medium', 'Low')),
  latitude double precision not null,
  longitude double precision not null,
  status text not null default 'resolved' check (status in ('reported', 'assigned', 'in_progress', 'resolved', 'resolved by other')),
  created_at timestamptz not null default now(),
  image_url text,
  voice_note_url text,
  officer_uid uuid references public.officers(id) on delete set null,
  current_site_id uuid references public.sites(id) on delete set null,
  orphaned boolean not null default false,
  resolved_at timestamptz,
  ranking_score double precision,
  assigned_to uuid references public.hse_workers(id) on delete set null,
  assigned_at timestamptz,
  started_at timestamptz,
  resolution_notes text,
  resolution_image_url text,
  resolution_voice_note_url text,
  report_number text
);

create table if not exists public.user_fcm_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  fcm_token text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.officer_emergency_contacts (
  id uuid primary key default gen_random_uuid(),
  officer_id uuid references public.officers(id) on delete cascade,
  officer_uid uuid references public.officers(id) on delete cascade,
  contact_name text,
  relationship text,
  personal text,
  blood_type text,
  chronic_conditions text,
  ambulance text,
  fire_brigade text,
  supervisor text,
  emergency_contact_name text,
  emergency_contact_phone text,
  emergency_contact_relation text,
  blood_group text,
  medical_conditions text,
  allergies text,
  medications text,
  home_address text
);

create table if not exists public.site_alerts (
  id uuid primary key default gen_random_uuid(),
  reporter_uid uuid not null references auth.users(id) on delete cascade,
  alert_type text not null,
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.error_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  error_message text not null,
  stack_trace text,
  created_at timestamptz not null default now()
);

create index if not exists idx_workers_officer_uid on public.workers(officer_uid);
create index if not exists idx_workers_current_site_id on public.workers(current_site_id);
create index if not exists idx_hse_workers_officer_uid on public.hse_workers(officer_uid);
create index if not exists idx_hse_workers_current_site_id on public.hse_workers(current_site_id);
create index if not exists idx_sites_officer_uid on public.sites(officer_uid);
create index if not exists idx_hazards_worker_id on public.hazards(worker_id);
create index if not exists idx_hazards_officer_uid on public.hazards(officer_uid);
create index if not exists idx_hazards_assigned_to on public.hazards(assigned_to);
create index if not exists idx_hazards_current_site_id on public.hazards(current_site_id);
create index if not exists idx_assign_hazards_worker_id on public.assign_hazards(worker_id);
create index if not exists idx_assign_hazards_officer_uid on public.assign_hazards(officer_uid);
create index if not exists idx_assign_hazards_assigned_to on public.assign_hazards(assigned_to);
create index if not exists idx_assign_hazards_current_site_id on public.assign_hazards(current_site_id);
create index if not exists idx_resolved_hazards_worker_id on public.resolved_hazards(worker_id);
create index if not exists idx_resolved_hazards_officer_uid on public.resolved_hazards(officer_uid);
create index if not exists idx_resolved_hazards_assigned_to on public.resolved_hazards(assigned_to);
create index if not exists idx_resolved_hazards_current_site_id on public.resolved_hazards(current_site_id);
create index if not exists idx_error_logs_user_id on public.error_logs(user_id);
create index if not exists idx_site_alerts_reporter_uid on public.site_alerts(reporter_uid);
create index if not exists idx_user_fcm_tokens_user_id on public.user_fcm_tokens(user_id);

alter table public.officers enable row level security;
alter table public.sites enable row level security;
alter table public.workers enable row level security;
alter table public.hse_workers enable row level security;
alter table public.hazards enable row level security;
alter table public.assign_hazards enable row level security;
alter table public.resolved_hazards enable row level security;
alter table public.user_fcm_tokens enable row level security;
alter table public.officer_emergency_contacts enable row level security;
alter table public.site_alerts enable row level security;
alter table public.error_logs enable row level security;

create policy "officers_select_own"
  on public.officers for select to authenticated
  using (id = auth.uid() or officer_uid = auth.uid());

create policy "officers_insert_own"
  on public.officers for insert to authenticated
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "officers_update_own"
  on public.officers for update to authenticated
  using (id = auth.uid() or officer_uid = auth.uid())
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "officers_delete_own"
  on public.officers for delete to authenticated
  using (id = auth.uid() or officer_uid = auth.uid());

create policy "sites_select_related"
  on public.sites for select to authenticated
  using (officer_uid = auth.uid());

create policy "sites_insert_related"
  on public.sites for insert to authenticated
  with check (officer_uid = auth.uid());

create policy "sites_update_related"
  on public.sites for update to authenticated
  using (officer_uid = auth.uid())
  with check (officer_uid = auth.uid());

create policy "sites_delete_related"
  on public.sites for delete to authenticated
  using (officer_uid = auth.uid());

create policy "workers_select_related"
  on public.workers for select to authenticated
  using (id = auth.uid() or officer_uid = auth.uid());

create policy "workers_insert_related"
  on public.workers for insert to authenticated
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "workers_update_related"
  on public.workers for update to authenticated
  using (id = auth.uid() or officer_uid = auth.uid())
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "workers_delete_related"
  on public.workers for delete to authenticated
  using (officer_uid = auth.uid());

create policy "hse_workers_select_related"
  on public.hse_workers for select to authenticated
  using (id = auth.uid() or officer_uid = auth.uid());

create policy "hse_workers_insert_related"
  on public.hse_workers for insert to authenticated
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "hse_workers_update_related"
  on public.hse_workers for update to authenticated
  using (id = auth.uid() or officer_uid = auth.uid())
  with check (id = auth.uid() or officer_uid = auth.uid());

create policy "hse_workers_delete_related"
  on public.hse_workers for delete to authenticated
  using (officer_uid = auth.uid());

create policy "hazards_select_related"
  on public.hazards for select to authenticated
  using (worker_id = auth.uid() or officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "hazards_insert_related"
  on public.hazards for insert to authenticated
  with check (worker_id = auth.uid() or officer_uid = auth.uid());

create policy "hazards_update_related"
  on public.hazards for update to authenticated
  using (worker_id = auth.uid() or officer_uid = auth.uid() or assigned_to = auth.uid())
  with check (worker_id = auth.uid() or officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "hazards_delete_related"
  on public.hazards for delete to authenticated
  using (officer_uid = auth.uid());

create policy "assign_hazards_select_related"
  on public.assign_hazards for select to authenticated
  using (worker_id = auth.uid() or officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "assign_hazards_insert_related"
  on public.assign_hazards for insert to authenticated
  with check (officer_uid = auth.uid());

create policy "assign_hazards_update_related"
  on public.assign_hazards for update to authenticated
  using (officer_uid = auth.uid() or assigned_to = auth.uid())
  with check (officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "assign_hazards_delete_related"
  on public.assign_hazards for delete to authenticated
  using (officer_uid = auth.uid());

create policy "resolved_hazards_select_related"
  on public.resolved_hazards for select to authenticated
  using (worker_id = auth.uid() or officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "resolved_hazards_insert_related"
  on public.resolved_hazards for insert to authenticated
  with check (officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "resolved_hazards_update_related"
  on public.resolved_hazards for update to authenticated
  using (officer_uid = auth.uid() or assigned_to = auth.uid())
  with check (officer_uid = auth.uid() or assigned_to = auth.uid());

create policy "resolved_hazards_delete_related"
  on public.resolved_hazards for delete to authenticated
  using (officer_uid = auth.uid());

create policy "user_fcm_tokens_select_own"
  on public.user_fcm_tokens for select to authenticated
  using (user_id = auth.uid());

create policy "user_fcm_tokens_insert_own"
  on public.user_fcm_tokens for insert to authenticated
  with check (user_id = auth.uid());

create policy "user_fcm_tokens_update_own"
  on public.user_fcm_tokens for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "user_fcm_tokens_delete_own"
  on public.user_fcm_tokens for delete to authenticated
  using (user_id = auth.uid());

create policy "officer_emergency_contacts_select_related"
  on public.officer_emergency_contacts for select to authenticated
  using (officer_id = auth.uid() or officer_uid = auth.uid());

create policy "officer_emergency_contacts_insert_related"
  on public.officer_emergency_contacts for insert to authenticated
  with check (officer_id = auth.uid() or officer_uid = auth.uid());

create policy "officer_emergency_contacts_update_related"
  on public.officer_emergency_contacts for update to authenticated
  using (officer_id = auth.uid() or officer_uid = auth.uid())
  with check (officer_id = auth.uid() or officer_uid = auth.uid());

create policy "officer_emergency_contacts_delete_related"
  on public.officer_emergency_contacts for delete to authenticated
  using (officer_id = auth.uid() or officer_uid = auth.uid());

create policy "site_alerts_select_own"
  on public.site_alerts for select to authenticated
  using (reporter_uid = auth.uid());

create policy "site_alerts_insert_own"
  on public.site_alerts for insert to authenticated
  with check (reporter_uid = auth.uid());

create policy "site_alerts_update_own"
  on public.site_alerts for update to authenticated
  using (reporter_uid = auth.uid())
  with check (reporter_uid = auth.uid());

create policy "site_alerts_delete_own"
  on public.site_alerts for delete to authenticated
  using (reporter_uid = auth.uid());

create policy "error_logs_select_own"
  on public.error_logs for select to authenticated
  using (user_id = auth.uid());

create policy "error_logs_insert_own_or_null"
  on public.error_logs for insert to authenticated
  with check (user_id = auth.uid() or user_id is null);

create policy "error_logs_update_own"
  on public.error_logs for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "error_logs_delete_own"
  on public.error_logs for delete to authenticated
  using (user_id = auth.uid());

insert into storage.buckets (id, name, public)
values ('hazard-images', 'hazard-images', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('voice_notes', 'voice_notes', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('profile-images', 'profile-images', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('resolutions', 'resolutions', true)
on conflict (id) do nothing;
