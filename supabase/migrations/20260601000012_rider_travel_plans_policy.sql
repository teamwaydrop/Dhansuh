-- =====================================================================
-- Migration: Expand SELECT Policy for rider_travel_plans
-- Date: 2026-06-01
-- Description: Allows owner riders to view/manage their own travel plans
--              regardless of their status, while others can see active ones.
-- =====================================================================

DROP POLICY IF EXISTS "Allow authenticated users to view active travel plans" ON public.rider_travel_plans;

CREATE POLICY "Allow authenticated users to view active travel plans"
ON public.rider_travel_plans
FOR SELECT
TO authenticated
USING (
    status = 'active'::public.travel_plan_status_enum
    OR
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
    )
);
