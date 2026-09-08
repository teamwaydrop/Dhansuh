-- =====================================================================
-- Migration: Add SELECT policy for pricing_zones
-- Date: 2026-06-11
-- Description: Enables RLS and adds a policy to allow public/authenticated
--              read-only access to pricing zones from the mobile app.
-- =====================================================================

-- Ensure RLS is enabled on pricing_zones
ALTER TABLE public.pricing_zones ENABLE ROW LEVEL SECURITY;

-- Drop policy if it exists to avoid conflicts
DROP POLICY IF EXISTS "Allow public read access to pricing_zones" ON public.pricing_zones;

-- Create policy to allow read access to any authenticated or anon user
CREATE POLICY "Allow public read access to pricing_zones"
ON public.pricing_zones
FOR SELECT
TO anon, authenticated
USING (true);
