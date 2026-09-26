-- Remove unnecessary direct DELETE access from site_alerts.
--
-- SOS records are retained for audit/history. Authenticated clients may
-- create scoped alerts and read authorized site alerts, while acknowledgement
-- and cancellation are handled through dedicated RPCs.

drop policy if exists "site_alerts_delete_own"
on public.site_alerts;
