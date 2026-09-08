-- =====================================================================
-- SECURITY FIX (H5 / M20 from the production audit, plus one issue the audit
-- missed): rider_assignments write policies on LIVE PRODUCTION are more
-- permissive than any committed migration intended, confirmed by querying
-- pg_policies directly on the linked project:
--
--   1. "Authenticated can insert rider assignments" (FOR INSERT, WITH CHECK
--      true) -- from the very first baseline migration, never dropped or
--      narrowed by anything since -- lets ANY authenticated user (rider,
--      passenger, or anyone else) insert an arbitrary row into
--      rider_assignments for ANY order_id/rider_id/assignment_status. This
--      coexists with the two properly owner-scoped INSERT policies below, so
--      it alone defeats them (Postgres OR-combines permissive RLS policies).
--
--   2. "Allow passengers to update assignments for their own orders" is
--      running the OLD unscoped check_is_order_passenger() predicate on
--      production, not the intercity-only check_is_order_passenger_for_
--      intercity() that 20260716000002_restrict_passenger_rider_assignments_
--      to_intercity.sql was written to install -- production drifted from
--      that migration's intent (most likely a later dashboard edit reapplied
--      the old predicate under the same policy name). A passenger can
--      currently forge assignment_status/distance_km/estimated_earnings on
--      a LOCAL ride/parcel order's assignment row, not just intercity ones.
--
--   3. Neither the rider's nor the passenger's own UPDATE/INSERT policy
--      restricts WHICH assignment_status values a self-write may set --
--      only order/rider ownership is checked. Either role can directly PATCH
--      assignment_status to 'accepted' (a real dispatch decision, otherwise
--      set exclusively by accept-order/confirm_intercity_search_rider under
--      the service-role key) or any other value.
--
-- Confirmed-legitimate direct (own-session, non-edge-function) writes, from
-- an exhaustive grep of every `.from('rider_assignments').update/insert(...)`
-- call site in lib/:
--   Rider:     assignment_status IN ('sent', 'expired')
--     - rider_home_tab.dart (~2193-2210): rider proactively offers on an
--       intercity Travel Together order ('sent').
--     - rider_orders_screen.dart / incoming_order_card.dart: client-side
--       countdown expiry ('expired').
--   Passenger: assignment_status IN ('accepted_by_user', 'rejected')
--     - intercity_searching_screen.dart (~730-817): passenger accepts/
--       rejects a rider's travel-plan offer in the Travel Together
--       marketplace.
-- 'accepted' and every other order-lifecycle status are set exclusively by
-- accept-order/start-dispatch/confirm_intercity_search_rider, all running
-- under the service-role key (bypasses RLS) -- entirely unaffected below.
-- =====================================================================

-- 0. check_is_order_passenger_for_intercity() was supposed to already exist
--    (20260716000002_restrict_passenger_rider_assignments_to_intercity.sql,
--    recorded as applied in supabase_migrations.schema_migrations) but does
--    NOT exist on the live linked project -- confirmed via direct pg_proc
--    query. Re-creating it here (idempotent, byte-identical to that
--    migration's definition) so the policies below have a real function to
--    call instead of failing at apply time.
CREATE OR REPLACE FUNCTION public.check_is_order_passenger_for_intercity(p_order_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id
          AND user_id = p_user_id
          AND order_type IN ('intercity_ride', 'intercity_parcel')
    );
$$;

-- 1. Remove the fully-open INSERT policy. The two role-scoped INSERT
--    policies (fixed in step 2/3 below) already cover every legitimate path.
DROP POLICY IF EXISTS "Authenticated can insert rider assignments" ON public.rider_assignments;

-- 2. Consolidate the two duplicate rider UPDATE policies (identical
--    ownership predicate, same effect) into one, restricted to the
--    confirmed-legitimate status values.
DROP POLICY IF EXISTS "Riders can update own assignments" ON public.rider_assignments;
DROP POLICY IF EXISTS "Allow riders to update their own assignments" ON public.rider_assignments;
CREATE POLICY "Allow riders to update their own assignments"
ON public.rider_assignments
FOR UPDATE
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.riders r WHERE r.id = rider_assignments.rider_id AND r.user_id = auth.uid())
)
WITH CHECK (
    EXISTS (SELECT 1 FROM public.riders r WHERE r.id = rider_assignments.rider_id AND r.user_id = auth.uid())
    AND assignment_status IN ('sent', 'expired')
);

-- 3. Restrict the rider INSERT policy the same way.
DROP POLICY IF EXISTS "Allow riders to insert their own assignments" ON public.rider_assignments;
CREATE POLICY "Allow riders to insert their own assignments"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    EXISTS (SELECT 1 FROM public.riders r WHERE r.id = rider_assignments.rider_id AND r.user_id = auth.uid())
    AND assignment_status IN ('sent', 'expired')
);

-- 4. Re-apply the intercity-only scoping (production had drifted back to the
--    unscoped helper) and restrict passenger self-writes to the two values
--    the Travel Together flow actually sends.
DROP POLICY IF EXISTS "Allow passengers to update assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to update assignments for their own orders"
ON public.rider_assignments
FOR UPDATE
TO authenticated
USING (
    public.check_is_order_passenger_for_intercity(order_id, auth.uid())
)
WITH CHECK (
    public.check_is_order_passenger_for_intercity(order_id, auth.uid())
    AND assignment_status IN ('accepted_by_user', 'rejected')
);

DROP POLICY IF EXISTS "Allow passengers to insert assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to insert assignments for their own orders"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    public.check_is_order_passenger_for_intercity(order_id, auth.uid())
    AND assignment_status IN ('accepted_by_user', 'rejected')
);
