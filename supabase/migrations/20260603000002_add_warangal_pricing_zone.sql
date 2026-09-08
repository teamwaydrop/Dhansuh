-- =====================================================================
-- Migration: Add Warangal Pricing Zone and Deactivate Other Zones
-- Date: 2026-06-10
-- Description: Inserts a new pricing zone for Warangal and marks the
--              other generic zones (Tier 1 & Tier 2) as inactive.
-- =====================================================================

-- 1. Deactivate other pricing zones
UPDATE public.pricing_zones
SET is_active = false
WHERE zone_code IN ('ZONE_TIER_1', 'ZONE_TIER_2');

-- 2. Insert new pricing zone for Warangal
INSERT INTO public.pricing_zones (
    id,
    zone_code,
    zone_name,
    zone_type,
    cities,
    is_active
) VALUES (
    'c6c39f1b-5042-48be-8434-1e53996f7b40',
    'ZONE_WARANGAL',
    'Warangal Zone',
    'warangal',
    ARRAY['Warangal', 'Hanamkonda', 'Kazipet'],
    true
)
ON CONFLICT (zone_code) 
DO UPDATE SET 
    zone_name = EXCLUDED.zone_name,
    zone_type = EXCLUDED.zone_type,
    cities = EXCLUDED.cities,
    is_active = EXCLUDED.is_active;
