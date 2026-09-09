-- =============================================================================
-- PRE-LAUNCH BLOCKER FIX 1 -- police_sos_logs RLS hardening
--
-- Ref: docs/OPS_final_readiness_audit_2026-09-09.md  (Part 5 / Part 6 RED)
--
-- CURRENT STATE (verified live 2026-09-09):
--   police_sos_logs has RLS enabled, and exactly two policies:
--     * SELECT "Allow authenticated to select police sos logs"  USING (true)
--     * INSERT "Allow riders to insert police sos logs"          WITH CHECK (true)
--   => ANY authenticated user can read EVERY SOS record (rider_id, order_id,
--      exact GPS coordinates, police_reference_code, support_ticket_code) and
--      can INSERT a forged row for ANY rider_id.
--   There is no UPDATE or DELETE policy -> rows are already immutable to every
--   client role (only service_role / SECURITY DEFINER can change them). That
--   part is fine and is left exactly as-is.
--
-- THE ONLY LEGITIMATE WRITER (verified in code):
--   lib/features/rider/orders/screens/rider_active_order_screen.dart
--   _triggerPoliceSOS() -> supabase.from('police_sos_logs')
--       .insert({ order_id, rider_id: order['rider_id'], rider_lat, rider_lng,
--                 latitude, longitude })
--       .select('police_reference_code, support_ticket_code').single();
--   i.e. the assigned rider inserts a row carrying THEIR OWN riders.id and then
--   reads back the two generated codes. No passenger and no Edge Function ever
--   writes or reads this table.
--
-- REPLACEMENT POLICIES:
--   SELECT : the reporting rider (rider_id -> riders.user_id = auth.uid())
--            OR an admin (public.is_admin()).
--            -> the rider can still read back the row they just inserted;
--               no other passenger/rider can see anyone else's SOS records;
--               there is still no public/anon access.
--   INSERT : WITH CHECK the row's rider_id belongs to the caller
--            (rider_id IN (SELECT id FROM riders WHERE user_id = auth.uid())).
--            -> the assigned rider's own insert still passes; forging a row for
--               another rider_id is now rejected.
--   UPDATE / DELETE : still no policy -> still denied for every client role
--            (service_role keeps its BYPASSRLS access for ops corrections).
--
-- The BEFORE INSERT trigger generate_police_reference_code() is independent of
-- RLS and is not touched -- both codes are still generated on insert.
--
-- IDEMPOTENT: DROP POLICY IF EXISTS + CREATE POLICY. Re-runnable.
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

-- =============================================================================
-- ROLLBACK (run manually to restore the exact pre-fix state):
--
--   DROP POLICY IF EXISTS "police_sos_logs_select_own_or_admin" ON public.police_sos_logs;
--   DROP POLICY IF EXISTS "police_sos_logs_insert_own_rider"    ON public.police_sos_logs;
--   CREATE POLICY "Allow authenticated to select police sos logs"
--       ON public.police_sos_logs FOR SELECT TO authenticated USING (true);
--   CREATE POLICY "Allow riders to insert police sos logs"
--       ON public.police_sos_logs FOR INSERT TO authenticated WITH CHECK (true);
--
-- (Nothing else is touched -- no table data, no trigger, no grant, no other
--  table, no function.)
-- =============================================================================
