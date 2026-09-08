-- =====================================================================
-- Migration: Configurable Intercity Ride pricing (price per KM)
-- Date: 2026-07-17
-- Description: Passenger-side intercity ride booking was showing no fare
--              because no pricing_config row existed for
--              service_type = 'intercity_ride'. The calculate-order-pricing
--              Edge Function (already used by PricingController for every
--              order type) resolves fare purely from pricing_config rows
--              matched by (service_type, vehicle_type, pricing_zone_id) —
--              nothing in the Flutter app hardcodes a rate.
--
--              This adds one pricing_config row per vehicle type (bike,
--              auto, cab) for every currently active pricing zone, using
--              pricing_rules = { base_km: 0, base_price: 0,
--              after_base_per_km: 3, minimum_fare: 0 } so that
--              calculateFare() in the Edge Function reduces to exactly
--              Fare = Distance x 3 (before the same commission/GST that
--              every other price in the app already applies). Way Drop can
--              change the ₹3/km rate at any time by updating
--              pricing_rules->>'after_base_per_km' on these rows — no app
--              release required.
-- =====================================================================

INSERT INTO public.pricing_config (
    pricing_code,
    service_type,
    vehicle_type,
    pricing_zone_id,
    commission_percentage,
    gst_percentage,
    max_boost_percentage,
    pricing_rules,
    approval_status,
    is_active,
    created_by_admin_id
)
SELECT
    'INTERCITY_RIDE_' || UPPER(v.vehicle_type) || '_' || z.zone_code,
    'intercity_ride',
    v.vehicle_type,
    z.id,
    v.commission_percentage,
    5,
    50,
    jsonb_build_object(
        'pricing_type', 'per_km_flat',
        'base_km', 0,
        'base_price', 0,
        'minimum_fare', 0,
        'after_base_per_km', 3
    ),
    'approved',
    true,
    (SELECT id FROM public.admins WHERE is_active = true ORDER BY created_at ASC LIMIT 1)
FROM public.pricing_zones z
CROSS JOIN (
    VALUES ('bike', 10), ('auto', 2), ('cab', 14)
) AS v(vehicle_type, commission_percentage)
WHERE z.is_active = true
  AND NOT EXISTS (
      SELECT 1 FROM public.pricing_config pc
      WHERE pc.service_type = 'intercity_ride'
        AND pc.vehicle_type = v.vehicle_type
        AND pc.pricing_zone_id = z.id
  )
  -- Guard added post-hoc: created_by_admin_id is NOT NULL and this migration
  -- resolves it via "first active admin". Every real (prod/staging)
  -- environment already has an admin row by this point, so this is a no-op
  -- there; it only changes behavior on a brand-new database with zero admins
  -- (e.g. a fresh local `supabase db reset`), where the insert is skipped
  -- instead of violating the NOT NULL constraint and aborting the migration.
  AND EXISTS (SELECT 1 FROM public.admins WHERE is_active = true);
