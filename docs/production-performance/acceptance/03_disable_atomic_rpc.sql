-- Emergency fail-closed option for the NEW handler. Keep the uniqueness index.
-- Review/approval required; this file defaults to ROLLBACK.
BEGIN;
SET LOCAL lock_timeout='1s';
DO $$ BEGIN IF md5(pg_get_functiondef('public.claim_order_assignment_atomic(uuid,uuid,uuid)'::regprocedure)) IS DISTINCT FROM 'fda16ff66c2f17b4350ae33d39e5db6c' THEN RAISE EXCEPTION 'Acceptance function drift'; END IF; END $$;
REVOKE EXECUTE ON FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) FROM service_role;
ROLLBACK;
