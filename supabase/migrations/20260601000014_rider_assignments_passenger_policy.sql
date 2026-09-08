-- Migration: Add SELECT, UPDATE, and INSERT policies on rider_assignments for passengers
DROP POLICY IF EXISTS "Allow passengers to view assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to view assignments for their own orders"
ON public.rider_assignments
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = rider_assignments.order_id
          AND o.user_id = auth.uid()
    )
);

DROP POLICY IF EXISTS "Allow passengers to update assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to update assignments for their own orders"
ON public.rider_assignments
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = rider_assignments.order_id
          AND o.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = rider_assignments.order_id
          AND o.user_id = auth.uid()
    )
);

DROP POLICY IF EXISTS "Allow passengers to insert assignments for their own orders" ON public.rider_assignments;
CREATE POLICY "Allow passengers to insert assignments for their own orders"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = rider_assignments.order_id
          AND o.user_id = auth.uid()
    )
);
