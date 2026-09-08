-- Migration: Fix infinite recursion in public.orders and public.rider_assignments SELECT policies

-- 1. Create SECURITY DEFINER helper functions to check access without triggering RLS recursively.
-- This checks if a given user is the passenger of the order.
CREATE OR REPLACE FUNCTION public.check_is_order_passenger(p_order_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id AND user_id = p_user_id
    );
$$;

-- This checks if a given user is a candidate rider for the order.
CREATE OR REPLACE FUNCTION public.check_is_order_candidate_rider(p_order_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.rider_assignments ra
        INNER JOIN public.riders r ON r.id = ra.rider_id
        WHERE ra.order_id = p_order_id AND r.user_id = p_user_id
    );
$$;

-- 2. Update SELECT policy on public.rider_assignments for passengers
DROP POLICY IF EXISTS "Allow passengers to view assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to view assignments for their own orders"
ON public.rider_assignments
FOR SELECT
TO authenticated
USING (
    public.check_is_order_passenger(order_id, auth.uid())
);

-- 3. Update UPDATE policy on public.rider_assignments for passengers
DROP POLICY IF EXISTS "Allow passengers to update assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to update assignments for their own orders"
ON public.rider_assignments
FOR UPDATE
TO authenticated
USING (
    public.check_is_order_passenger(order_id, auth.uid())
)
WITH CHECK (
    public.check_is_order_passenger(order_id, auth.uid())
);

-- 4. Update INSERT policy on public.rider_assignments for passengers
DROP POLICY IF EXISTS "Allow passengers to insert assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to insert assignments for their own orders"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    public.check_is_order_passenger(order_id, auth.uid())
);

-- 5. Update SELECT policy on public.orders
DROP POLICY IF EXISTS "Allow users to view their own or assigned orders" ON public.orders;
CREATE POLICY "Allow users to view their own or assigned orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
    auth.uid() = user_id
    OR
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = orders.rider_id
          AND r.user_id = auth.uid()
    )
    OR
    public.check_is_order_candidate_rider(id, auth.uid())
);
