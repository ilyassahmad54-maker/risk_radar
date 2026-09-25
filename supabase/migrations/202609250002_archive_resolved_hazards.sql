-- Archive resolved hazard assignments.
--
-- When an HSE/Safety Officer changes an assign_hazards row to "resolved",
-- preserve the completed assignment in resolved_hazards.
--
-- assign_hazards and resolved_hazards intentionally share the same schema.

create or replace function public.archive_resolved_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'resolved'
     and (old.status is distinct from 'resolved') then

    insert into public.resolved_hazards
    select new.*
    on conflict (id) do update
    set
      status = excluded.status,
      resolved_at = excluded.resolved_at,
      resolution_notes = excluded.resolution_notes,
      report_number = excluded.report_number,
      resolution_image_url = excluded.resolution_image_url,
      resolution_voice_note_url = excluded.resolution_voice_note_url;

  end if;

  return new;
end;
$$;

drop trigger if exists assign_hazards_archive_resolved
on public.assign_hazards;

create trigger assign_hazards_archive_resolved
after update of status
on public.assign_hazards
for each row
execute function public.archive_resolved_assignment();
