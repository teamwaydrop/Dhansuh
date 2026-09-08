-- Migration: Restrict passenger UPDATE/INSERT on rider_assignments to intercity orders only.
-- Date: 2026-07-16
--
-- The passenger UPDATE/INSERT policies on rider_assignments (20260601000015_fix_orders_recursion.sql)
-- are gated only by order ownership via check_is_order_passenger(), with no restriction on order type.
-- The only legitimate passenger-driven writes to rider_assignments are in the intercity trip-sharing
-- marketplace flow (lib/features/intercity/shared/screens/intercity_searching_screen.dart), where a
-- passenger accepts/rejects/confirms a rider's published travel plan directly. Local ride/parcel
-- orders are dispatched purely via the trigger/RPC path and should never be writable by a passenger.
-- Without this restriction, a passenger could forge assignment_status transitions (e.g. 'accepted')
-- or tamper with distance_km/estimated_earnings for a local ride/parcel order, bypassing dispatch
-- entirely.
--
-- This adds a new helper scoped to intercity order types and uses it only for the UPDATE/INSERT
-- policies. The SELECT policy (check_is_order_passenger) is left untouched.

-- 1. Helper: passenger owns the order AND the order is an intercity order.
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

-- 2. Narrow the passenger UPDATE policy to intercity orders only.
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
);

-- 3. Narrow the passenger INSERT policy to intercity orders only.
DROP POLICY IF EXISTS "Allow passengers to insert assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to insert assignments for their own orders"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    public.check_is_order_passenger_for_intercity(order_id, auth.uid())
);
