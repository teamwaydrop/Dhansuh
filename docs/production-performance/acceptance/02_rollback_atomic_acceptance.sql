-- REVIEW ONLY. No business rows are restored or deleted. Requires traffic drain.
-- Restore a reviewed Edge bundle only while acceptance remains paused. v60 has the known race.
BEGIN;
SET LOCAL lock_timeout='1s';
SET LOCAL statement_timeout='15s';
DO $guard$ BEGIN
  IF current_setting('app.acceptance_rollback_traffic_drained',true) IS DISTINCT FROM 'approved' THEN
    RAISE EXCEPTION 'Pause and drain acceptance traffic before object rollback';
  END IF;
  IF md5(pg_get_functiondef('public.claim_order_assignment_atomic(uuid,uuid,uuid)'::regprocedure)) IS DISTINCT FROM 'fda16ff66c2f17b4350ae33d39e5db6c' THEN
    RAISE EXCEPTION 'Acceptance function definition drift';
  END IF;
  IF pg_get_indexdef('public.rider_assignments_one_accepted_per_order'::regclass) IS DISTINCT FROM 'CREATE UNIQUE INDEX rider_assignments_one_accepted_per_order ON public.rider_assignments USING btree (order_id) WHERE (assignment_status = ''accepted''::intercity_assignment_status_enum)' THEN
    RAISE EXCEPTION 'Accepted-assignment index drift';
  END IF;
END $guard$;
DROP FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) RESTRICT;
DROP INDEX public.rider_assignments_one_accepted_per_order;
ROLLBACK;
