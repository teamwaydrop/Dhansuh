-- Migration: guarantee an active, approved pricing_config row exists for every (intercity_parcel,
-- vehicle_type, active pricing_zone) combination -- fixes "Unable to calculate fare" on intercity
-- parcel booking.
-- Date: 2026-08-06
--
-- ROOT CAUSE: 20260717000004_add_intercity_parcel_pricing_config.sql seeded these rows, but guarded
-- the INSERT with `AND EXISTS (SELECT 1 FROM public.admins WHERE is_active = true)` "so it no-ops
-- on a brand-new database with zero admins" (its own comment). If that migration happened to run
-- before any admin row existed, the guard silently skipped the insert entirely and nothing since
-- has re-attempted it -- every intercity parcel pricing request then 404s from
-- calculate-order-pricing/index.ts's resolvePricingConfig() ("No active pricing config found for
-- service..."), which the client surfaces as "Unable to calculate fare for this route" (pricing
-- itself, i.e. the ₹/km formula, is unchanged -- this only ensures the row exists so that existing
-- formula can be read).
--
-- FIX: re-run the exact same idempotent insert (still guarded by the same
-- `NOT EXISTS (... same service_type/vehicle_type/zone ...)` check, so this is a pure no-op
-- anywhere the row already exists) without the admin-existence precondition. created_by_admin_id
-- is nullable and simply resolves to NULL if genuinely no admin row exists yet, matching how the
-- intercity RIDE equivalent (20260717000001) already behaves when re-applied.
--
-- RECONCILIATION NOTE (2026-08-04): applied directly to the linked Supabase project but never
-- committed to this repo; reconstructed verbatim from supabase_migrations.schema_migrations.

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
  );
