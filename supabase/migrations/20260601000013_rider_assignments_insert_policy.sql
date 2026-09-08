-- Migration: Add INSERT policy for rider_assignments
DROP POLICY IF EXISTS "Allow riders to insert their own assignments" ON public.rider_assignments;
CREATE POLICY "Allow riders to insert their own assignments"
ON public.rider_assignments
FOR INSERT
TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_id
          AND r.user_id = auth.uid()
    )
);
