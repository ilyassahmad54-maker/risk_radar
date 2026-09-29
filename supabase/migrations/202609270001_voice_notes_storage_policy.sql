-- Allow authenticated RiskRadar users to upload hazard voice-note evidence.
-- Added after final regression testing identified a Storage RLS 403
-- when submitting hazards containing voice notes.

drop policy if exists "voice_notes_insert_authenticated"
on storage.objects;

create policy "voice_notes_insert_authenticated"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'voice_notes'
);
