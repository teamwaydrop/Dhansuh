-- Migration: correct intercity auto-vehicle commission from 2% to the required 10%.
-- Date: 2026-08-21
--
-- BUSINESS RULE (explicit, this session, confirmed via a read-only production verification):
--   Intercity passenger (intercity_ride): WayDrop commission = 10% for bike, auto, AND cab.
--   Intercity parcel (intercity_parcel): WayDrop commission = 10% for bike AND auto.
-- Production's live commission_percentage was verified (via a read-only call to the deployed
-- calculate-order-pricing edge function, the same read path the real booking flow uses) to be:
--   intercity_ride:   bike=10%, auto=2%, cab=10%
--   intercity_parcel: bike=10%, auto=2%
-- i.e. every vehicle type already matches the 10% rule EXCEPT auto on both service types, which is
-- currently 2%. This migration corrects exactly those two rows.
--
-- SCOPE: pricing_config.commission_percentage only, for (service_type, vehicle_type) in
-- {(intercity_ride, auto), (intercity_parcel, auto)}. Nothing else on these rows changes --
-- gst_percentage (Platform GST, must stay 5% for both, per explicit instruction: the 18% figure
-- for intercity parcel refers to the SEPARATE Government Tax/Section 9(5) system in
-- tax_rate_config, not this column -- see 20260901000021's header) and every other column
-- (pricing_rules, max_boost_percentage, approval_status, is_active, pricing_zone_id, etc.) are
-- completely untouched. bike/cab commission, local ride/parcel commission, and every non-'auto'
-- row anywhere in this table are untouched.
--
-- WHERE THIS TAKES EFFECT: commission_percentage is read from pricing_config exactly once, by
-- calculate-order-pricing/index.ts at booking time, and copied verbatim onto orders.
-- commission_percentage by create-order/index.ts's INSERT. No function anywhere (accept_
-- intercity_request(), complete_order_and_settle(), confirm_intercity_parcel_payment_received())
-- ever re-reads pricing_config for an existing order -- they all read the value already stamped on
-- the order at booking time. Consequences, confirmed:
--   - Only NEW bookings (orders created after this migration runs) are affected.
--   - Every existing/in-flight intercity auto order (searching, accepted, ongoing, payment_pending
--     -- anything already in the orders table) keeps whatever commission_percentage it was stamped
--     with at its own creation time. This migration writes nothing to the orders table at all.
--
-- SAFETY:
--   - Criteria-based UPDATE, not row-ID-based: pricing_config has no anon/client SELECT grant (by
--     design, confirmed via a read-only 403 against production), so exact row UUIDs/pricing_code
--     values could not be fetched to hardcode here. Matching on
--     (service_type, vehicle_type, is_active, commission_percentage) is self-scoping instead --
--     structurally incapable of touching a bike/cab row (vehicle_type filter), a local ride/parcel
--     row (service_type filter), or a row someone has already corrected to a different value (the
--     commission_percentage = 2 guard).
--   - Idempotent: re-running this migration after it has already applied once matches zero rows
--     (nothing will still be at commission_percentage = 2) and is a pure no-op.
--   - unique_active_pricing_config (20260529000000, UNIQUE on (service_type,
--     COALESCE(vehicle_type,''), COALESCE(pricing_zone_id::text,'')) WHERE is_active = true)
--     guarantees at most one active row per (service_type, vehicle_type, zone) combination --
--     combined with exactly one active pricing zone in production (ZONE_WARANGAL, confirmed via a
--     read-only query), this UPDATE affects EXACTLY 2 rows: intercity_ride/auto and
--     intercity_parcel/auto in ZONE_WARANGAL. No other zone/vehicle/service combination exists to
--     accidentally match.
--   - Pure UPDATE, no schema change, no function change, no RLS/grant change, no INSERT/DELETE.

UPDATE public.pricing_config
SET commission_percentage = 10,
    updated_at = now()
WHERE service_type IN ('intercity_ride', 'intercity_parcel')
  AND vehicle_type = 'auto'
  AND is_active = true
  AND commission_percentage = 2;
