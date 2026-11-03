-- =====================================================================
-- Migration: Configurable Intercity Parcel pricing (price per KM)
-- Date: 2026-07-17
-- Description: No pricing_config row exists for service_type =
--              'intercity_parcel', so calculate-order-pricing's
--              resolvePricingConfig() (supabase/functions/
--              calculate-order-pricing/index.ts) silently falls back to
--              'local_parcel' rates for every intercity parcel order.
--              This adds an explicit, independently-adjustable
--              pricing_config row per vehicle type (bike, auto — intercity
--              parcels never use cab, see create-order's
--              calculatedParcelVehicle) for every currently active pricing
--              zone, using pricing_rules = { base_km: 0, base_price: 0,
--              after_base_per_km: 3, minimum_fare: 0 } so that
--              calculateFare() reduces to exactly Fare = Distance x 3,
--              mirroring 20260717000001_add_intercity_ride_pricing_config.sql.
--              Way Drop can change the ₹3/km rate at any time by updating
--              pricing_rules->>'after_base_per_km' on these rows, and can
--              now price intercity parcels independently of local parcels
--              — no app release required either way.
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
    'INTERCITY_PARCEL_' || UPPER(v.vehicle_type) || '_' || z.zone_code,
    'intercity_parcel',
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
    VALUES ('bike', 10), ('auto', 2)
) AS v(vehicle_type, commission_percentage)
WHERE z.is_active = true
  AND NOT EXISTS (
      SELECT 1 FROM public.pricing_config pc
      WHERE pc.service_type = 'intercity_parcel'
        AND pc.vehicle_type = v.vehicle_type
        AND pc.pricing_zone_id = z.id
  )
  -- Guard added post-hoc: same reasoning as 20260717000001_add_intercity_ride_pricing_config.sql
  -- (no-op on any environment that already has an admin row; only skips the
  -- insert on a brand-new database with zero admins).
  AND EXISTS (SELECT 1 FROM public.admins WHERE is_active = true);
