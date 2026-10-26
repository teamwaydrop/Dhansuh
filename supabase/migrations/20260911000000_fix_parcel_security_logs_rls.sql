-- =============================================================================
-- SECURITY FIX -- public.parcel_security_logs RLS hardening
--
-- Ref: lawful-disclosure + security audit (2026-09-09/10).
--
-- CURRENT STATE (verified live 2026-09-10):
--   RLS enabled. Exactly two policies, both role `authenticated`:
--     * SELECT "Allow users/riders to select their parcel security logs"  USING (true)
--     * INSERT "Allow authenticated users to insert security logs"         WITH CHECK (true)
--   => ANY logged-in user can read every row (rider_id, order_id, sender_user_id,
--      pickup/drop event GPS: latitude/longitude + event_latitude/event_longitude,
--      device_id, ip_address, metadata, police_sos_opened events) and can INSERT
--      arbitrary/forged rows for any order_id.
--   Same over-exposure class as the police_sos_logs bug fixed in
--   20260910000000_fix_police_sos_logs_rls.sql -- parcel_security_logs was not in
--   that migration's scope.
--
-- ACTUAL USAGE (so this fix breaks nothing):
--   * Client reads: NONE (no `.from('parcel_security_logs').select(` anywhere in lib/).
--   * Client writes: ONE -- lib/features/rider/orders/screens/rider_active_order_screen.dart
--     logs a `police_sos_opened` row for the rider's OWN active order (row carries
--     rider_id = order.rider_id and sender_user_id = order.user_id).
--   * Edge Functions (create-order, process-verification-photo, update-order-status)
--     write as service_role and BYPASS RLS regardless of the policy.
--
-- REPLACEMENT POLICIES (role authenticated):
--   SELECT: public.is_admin()
--        OR sender_user_id = auth.uid()
--        OR rider_id IN (SELECT id FROM riders WHERE user_id = auth.uid())
--   INSERT: WITH CHECK ( sender_user_id = auth.uid()
--                        OR rider_id IN (SELECT id FROM riders WHERE user_id = auth.uid()) )
--   UPDATE / DELETE: no policy (unchanged) -> rows stay immutable to every client
--                    role; service_role keeps its BYPASSRLS access for ops.
--
-- No trigger, grant, or other table/policy is touched.
-- IDEMPOTENT: DROP POLICY IF EXISTS + CREATE POLICY. Safe to re-run.
-- =============================================================================

-- Drop the over-permissive policies (and the new names, for re-runnability).
DROP POLICY IF EXISTS "Allow users/riders to select their parcel security logs" ON public.parcel_security_logs;
DROP POLICY IF EXISTS "Allow authenticated users to insert security logs"        ON public.parcel_security_logs;
DROP POLICY IF EXISTS "parcel_security_logs_select_participant_or_admin"          ON public.parcel_security_logs;
DROP POLICY IF EXISTS "parcel_security_logs_insert_own_participant"               ON public.parcel_security_logs;

-- SELECT: the parcel's own sender or assigned rider, or an admin.
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

-- INSERT: the acting party may only create a row scoped to themselves
--         (as the sender, or as one of their own rider profiles).
--         service_role Edge Functions bypass this.
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

-- =============================================================================
-- ROLLBACK (run manually to restore the exact pre-fix state):
--
--   DROP POLICY IF EXISTS "parcel_security_logs_select_participant_or_admin" ON public.parcel_security_logs;
--   DROP POLICY IF EXISTS "parcel_security_logs_insert_own_participant"      ON public.parcel_security_logs;
--   CREATE POLICY "Allow users/riders to select their parcel security logs"
--       ON public.parcel_security_logs FOR SELECT TO authenticated USING (true);
--   CREATE POLICY "Allow authenticated users to insert security logs"
--       ON public.parcel_security_logs FOR INSERT TO authenticated WITH CHECK (true);
--
-- (Nothing else is touched -- no table data, trigger, grant, function, or other
--  table/policy.)
-- =============================================================================
