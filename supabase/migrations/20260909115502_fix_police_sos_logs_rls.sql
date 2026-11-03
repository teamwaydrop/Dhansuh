-- =============================================================================
-- PRE-LAUNCH BLOCKER FIX 1 -- police_sos_logs RLS hardening
-- Ref: docs/OPS_final_readiness_audit_2026-09-09.md  (Part 5 / Part 6 RED)
-- File: supabase/migrations/20260910000000_fix_police_sos_logs_rls.sql
-- =============================================================================

-- Drop the two over-permissive policies.
DROP POLICY IF EXISTS "Allow authenticated to select police sos logs" ON public.police_sos_logs;
DROP POLICY IF EXISTS "Allow riders to insert police sos logs"        ON public.police_sos_logs;

-- Also drop the new names first so this migration is safely re-runnable.
DROP POLICY IF EXISTS "police_sos_logs_select_own_or_admin" ON public.police_sos_logs;
DROP POLICY IF EXISTS "police_sos_logs_insert_own_rider"    ON public.police_sos_logs;

-- SELECT: reporting rider or admin only.
CREATE POLICY "police_sos_logs_select_own_or_admin"
    ON public.police_sos_logs
    FOR SELECT
    TO authenticated
    USING (
        public.is_admin()
        OR rider_id IN (
            SELECT r.id FROM public.riders r
            WHERE r.user_id = (SELECT auth.uid())
        )
    );

-- INSERT: the caller may only create a row for a rider profile they own.
CREATE POLICY "police_sos_logs_insert_own_rider"
    ON public.police_sos_logs
    FOR INSERT
    TO authenticated
    WITH CHECK (
        rider_id IN (
            SELECT r.id FROM public.riders r
            WHERE r.user_id = (SELECT auth.uid())
        )
    );
