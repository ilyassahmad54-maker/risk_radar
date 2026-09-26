-- ============================================================
-- RiskRadar: Lock down direct hazard lifecycle mutations
--
-- Hazard creation remains available through hazards INSERT.
--
-- Assignment/reassignment must use:
--   public.assign_hazard_to_hse(...)
--
-- HSE start/resolution must use:
--   public.update_hse_hazard_lifecycle(...)
--
-- resolved_hazards is populated by the trusted archive trigger.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- hazards
-- ------------------------------------------------------------
-- Keep:
--   hazards_select_related
--   hazards_insert_related
--
-- Remove direct lifecycle/destructive mutations.
drop policy if exists hazards_update_related
on public.hazards;

drop policy if exists hazards_delete_related
on public.hazards;


-- ------------------------------------------------------------
-- assign_hazards
-- ------------------------------------------------------------
-- Keep:
--   assign_hazards_select_related
--
-- All assignment and lifecycle writes must go through trusted
-- SECURITY DEFINER functions.
drop policy if exists assign_hazards_insert_related
on public.assign_hazards;

drop policy if exists assign_hazards_update_related
on public.assign_hazards;

drop policy if exists assign_hazards_delete_related
on public.assign_hazards;


-- ------------------------------------------------------------
-- resolved_hazards
-- ------------------------------------------------------------
-- Keep:
--   resolved_hazards_select_related
--
-- This archive must not be directly mutated by authenticated
-- clients. The trusted archive trigger/function performs writes.
drop policy if exists resolved_hazards_insert_related
on public.resolved_hazards;

drop policy if exists resolved_hazards_update_related
on public.resolved_hazards;

drop policy if exists resolved_hazards_delete_related
on public.resolved_hazards;

commit;
