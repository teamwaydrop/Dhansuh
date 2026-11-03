-- SECURITY FIX -- public.parcel_security_logs RLS hardening
-- File: supabase/migrations/20260911000000_fix_parcel_security_logs_rls.sql

DROP POLICY IF EXISTS "Allow users/riders to select their parcel security logs" ON public.parcel_security_logs;
DROP POLICY IF EXISTS "Allow authenticated users to insert security logs"        ON public.parcel_security_logs;
DROP POLICY IF EXISTS "parcel_security_logs_select_participant_or_admin"          ON public.parcel_security_logs;
DROP POLICY IF EXISTS "parcel_security_logs_insert_own_participant"               ON public.parcel_security_logs;

CREATE POLICY "parcel_security_logs_select_participant_or_admin"
    ON public.parcel_security_logs
    FOR SELECT
    TO authenticated
    USING (
        public.is_admin()
        OR sender_user_id = (SELECT auth.uid())
        OR rider_id IN (
            SELECT r.id FROM public.riders r
            WHERE r.user_id = (SELECT auth.uid())
        )
    );

CREATE POLICY "parcel_security_logs_insert_own_participant"
    ON public.parcel_security_logs
    FOR INSERT
    TO authenticated
    WITH CHECK (
        sender_user_id = (SELECT auth.uid())
        OR rider_id IN (
            SELECT r.id FROM public.riders r
            WHERE r.user_id = (SELECT auth.uid())
        )
    );
