-- ============================================================================
-- RiskRadar
-- Secure hazard assignment + HSE lifecycle RPCs
-- ============================================================================

CREATE OR REPLACE FUNCTION public.assign_hazard_to_hse(
  p_hazard_id uuid,
  p_assigned_to uuid,
  p_assigned_at timestamp with time zone DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  hazard_row public.hazards%rowtype;
  assigned_row public.assign_hazards%rowtype;
  hse_row public.hse_workers%rowtype;
begin
  -- Authentication is mandatory.
  if auth.uid() is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  ----------------------------------------------------------------------
  -- CASE 1: Hazard is still in hazards (initial assignment)
  ----------------------------------------------------------------------

  select *
    into hazard_row
    from public.hazards
   where id = p_hazard_id
   for update;

  if found then

    -- Only the contractor who owns this hazard may assign it.
    if hazard_row.officer_uid is null
       or hazard_row.officer_uid <> auth.uid() then
      raise exception 'You are not authorized to assign this hazard'
        using errcode = '42501';
    end if;

    -- Hazard must belong to one of the contractor's sites.
    if hazard_row.current_site_id is null
       or not exists (
         select 1
         from public.sites s
         where s.id = hazard_row.current_site_id
           and s.officer_uid = auth.uid()
       ) then
      raise exception 'Hazard does not belong to one of your sites'
        using errcode = '42501';
    end if;

    -- Selected HSE must belong to this contractor and this exact site.
    select *
      into hse_row
      from public.hse_workers h
     where h.id = p_assigned_to
       and h.officer_uid = auth.uid()
       and h.current_site_id = hazard_row.current_site_id
       and h.is_active = true
       and h.is_available = true;

    if not found then
      raise exception
        'Selected HSE worker is not available for this contractor/site'
        using errcode = '42501';
    end if;

    insert into public.assign_hazards (
      id,
      worker_id,
      hazard_type,
      description,
      severity,
      latitude,
      longitude,
      status,
      created_at,
      image_url,
      orphaned,
      resolved_at,
      ranking_score,
      officer_uid,
      voice_note_url,
      assigned_to,
      assigned_at,
      current_site_id
    )
    values (
      hazard_row.id,
      hazard_row.worker_id,
      hazard_row.hazard_type,
      hazard_row.description,
      hazard_row.severity,
      hazard_row.latitude,
      hazard_row.longitude,
      'assigned',
      hazard_row.created_at,
      hazard_row.image_url,
      hazard_row.orphaned,
      hazard_row.resolved_at,
      hazard_row.ranking_score,
      hazard_row.officer_uid,
      hazard_row.voice_note_url,
      p_assigned_to,
      p_assigned_at,
      hazard_row.current_site_id
    )
    on conflict (id) do update
       set assigned_to = excluded.assigned_to,
           assigned_at = excluded.assigned_at,
           status = 'assigned'
    returning * into assigned_row;

    delete from public.hazards
     where id = p_hazard_id;

    return jsonb_build_object(
      'success', true,
      'status', 'assigned',
      'hazard', to_jsonb(assigned_row)
    );
  end if;

  ----------------------------------------------------------------------
  -- CASE 2: Hazard already exists in assign_hazards (reassignment)
  ----------------------------------------------------------------------

  select *
    into assigned_row
    from public.assign_hazards
   where id = p_hazard_id
   for update;

  if not found then
    raise exception 'Hazard % was not found for assignment', p_hazard_id
      using errcode = 'P0002';
  end if;

  -- Only its contractor can reassign it.
  if assigned_row.officer_uid is null
     or assigned_row.officer_uid <> auth.uid() then
    raise exception 'You are not authorized to reassign this hazard'
      using errcode = '42501';
  end if;

  -- Assigned hazard must still belong to contractor's site.
  if assigned_row.current_site_id is null
     or not exists (
       select 1
       from public.sites s
       where s.id = assigned_row.current_site_id
         and s.officer_uid = auth.uid()
     ) then
    raise exception 'Hazard does not belong to one of your sites'
      using errcode = '42501';
  end if;

  -- New HSE must belong to same contractor + same site and be available.
  select *
    into hse_row
    from public.hse_workers h
   where h.id = p_assigned_to
     and h.officer_uid = auth.uid()
     and h.current_site_id = assigned_row.current_site_id
     and h.is_active = true
     and h.is_available = true;

  if not found then
    raise exception
      'Selected HSE worker is not available for this contractor/site'
      using errcode = '42501';
  end if;

  update public.assign_hazards
     set assigned_to = p_assigned_to,
         assigned_at = p_assigned_at,
         status = 'assigned'
   where id = p_hazard_id
   returning * into assigned_row;

  return jsonb_build_object(
    'success', true,
    'status', 'already_assigned',
    'hazard', to_jsonb(assigned_row)
  );
end;
$function$;


-- ============================================================================
-- Secure HSE hazard lifecycle
-- assigned -> in_progress -> resolved
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_hse_hazard_lifecycle(
  p_hazard_id uuid,
  p_new_status text,
  p_resolution_notes text DEFAULT NULL::text,
  p_resolution_image_url text DEFAULT NULL::text,
  p_resolution_voice_note_url text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_hazard public.assign_hazards%rowtype;
begin
  -- Authentication is mandatory.
  if auth.uid() is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  -- Lock the assignment while validating/updating it.
  select *
    into v_hazard
    from public.assign_hazards
   where id = p_hazard_id
   for update;

  if not found then
    raise exception 'Assigned hazard was not found'
      using errcode = 'P0002';
  end if;

  -- Only the HSE worker assigned to this hazard may change its lifecycle.
  if v_hazard.assigned_to is null
     or v_hazard.assigned_to <> auth.uid() then
    raise exception 'You are not assigned to this hazard'
      using errcode = '42501';
  end if;

  ----------------------------------------------------------------------
  -- START TASK
  ----------------------------------------------------------------------

  if p_new_status = 'in_progress' then

    -- Only an assigned task may be started.
    if v_hazard.status <> 'assigned' then
      raise exception
        'Hazard cannot transition from % to in_progress',
        v_hazard.status
        using errcode = '22023';
    end if;

    update public.assign_hazards
       set status = 'in_progress',
           started_at = coalesce(started_at, now())
     where id = p_hazard_id
     returning * into v_hazard;

  ----------------------------------------------------------------------
  -- RESOLVE TASK
  ----------------------------------------------------------------------

  elsif p_new_status = 'resolved' then

    -- Resolution is only allowed after the task has been started.
    if v_hazard.status <> 'in_progress' then
      raise exception
        'Hazard cannot transition from % to resolved',
        v_hazard.status
        using errcode = '22023';
    end if;

    if p_resolution_notes is null
       or btrim(p_resolution_notes) = '' then
      raise exception 'Resolution notes are required'
        using errcode = '22023';
    end if;

    update public.assign_hazards
       set status = 'resolved',
           resolved_at = now(),
           resolution_notes = btrim(p_resolution_notes),
           resolution_image_url = nullif(
             btrim(p_resolution_image_url),
             ''
           ),
           resolution_voice_note_url = nullif(
             btrim(p_resolution_voice_note_url),
             ''
           )
     where id = p_hazard_id
     returning * into v_hazard;

  else
    raise exception 'Unsupported lifecycle status: %', p_new_status
      using errcode = '22023';
  end if;

  return jsonb_build_object(
    'success', true,
    'status', v_hazard.status,
    'hazard', to_jsonb(v_hazard)
  );
end;
$function$;


-- ============================================================================
-- RPC permissions
-- ============================================================================

REVOKE ALL ON FUNCTION public.assign_hazard_to_hse(
  uuid,
  uuid,
  timestamp with time zone
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.assign_hazard_to_hse(
  uuid,
  uuid,
  timestamp with time zone
) TO authenticated;


REVOKE ALL ON FUNCTION public.update_hse_hazard_lifecycle(
  uuid,
  text,
  text,
  text,
  text
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.update_hse_hazard_lifecycle(
  uuid,
  text,
  text,
  text,
  text
) TO authenticated;