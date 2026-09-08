-- =====================================================================
-- Migration: Lock (snapshot) Intercity Travel Plan fare at creation time
-- Date: 2026-07-17
-- Description: Today the passenger-facing "price per seat" for a Travel
--              Plan is recomputed on every search from the PASSENGER's own
--              live distance via PricingController -> calculate-order-pricing
--              -> pricing_config. That means the same plan can show a
--              different price on different days if Way Drop edits
--              pricing_config, which violates the business rule that a
--              Travel Plan's price must be fixed at the moment the Drop
--              Partner posts it.
--
--              This adds a fare snapshot to rider_travel_plans itself:
--                distance_km          - the plan's own route distance
--                base_fare_per_seat   - base fare at creation time (pre-GST)
--                gst_amount_per_seat  - GST amount at creation time
--                price_per_seat       - base_fare_per_seat + gst_amount_per_seat
--                                       (what a passenger pays per seat)
--
--              Going forward, post_travel_plan_screen.dart computes and
--              writes these once, at INSERT time, via the same
--              PricingController / pricing_config pipeline already used
--              everywhere else (calculate-order-pricing, service_type =
--              'intercity_ride') — no new pricing logic, no hardcoded rate.
--              The passenger-side booking screen then reads these stored
--              columns instead of recalculating, so existing plans keep
--              their original price even after pricing_config changes.
--
--              A handful of Travel Plans already exist with no fare
--              snapshot (created before this migration). Backfill those
--              using the same intercity_ride pricing_config rows and a
--              straight-line (haversine) distance between their stored
--              pickup/destination coordinates, so passengers don't see a
--              ₹0.00 fare for plans that were already posted.
-- =====================================================================

ALTER TABLE public.rider_travel_plans
    ADD COLUMN IF NOT EXISTS distance_km NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS base_fare_per_seat NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS gst_amount_per_seat NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS price_per_seat NUMERIC NOT NULL DEFAULT 0;

-- One-time backfill for plans created before this migration existed.
WITH plan_distance AS (
    SELECT
        tp.id,
        tp.vehicle_type,
        6371 * acos(
            LEAST(1, GREATEST(-1,
                cos(radians(tp.pickup_lat)) * cos(radians(tp.destination_lat)) *
                cos(radians(tp.destination_lng) - radians(tp.pickup_lng)) +
                sin(radians(tp.pickup_lat)) * sin(radians(tp.destination_lat))
            ))
        ) AS distance_km
    FROM public.rider_travel_plans tp
    WHERE tp.price_per_seat = 0
      AND tp.status IN ('active', 'fully_booked')
      AND tp.vehicle_type IS NOT NULL
      AND tp.pickup_lat IS NOT NULL AND tp.pickup_lng IS NOT NULL
      AND tp.destination_lat IS NOT NULL AND tp.destination_lng IS NOT NULL
),
matched_config AS (
    SELECT
        pd.id,
        pd.distance_km,
        (pc.pricing_rules->>'after_base_per_km')::numeric AS per_km_rate,
        pc.gst_percentage
    FROM plan_distance pd
    JOIN public.pricing_config pc
      ON pc.service_type = 'intercity_ride'
     AND pc.vehicle_type = pd.vehicle_type::text
     AND pc.is_active = true
     AND pc.approval_status = 'approved'
     AND pc.pricing_zone_id = (SELECT id FROM public.pricing_zones WHERE is_active = true LIMIT 1)
)
UPDATE public.rider_travel_plans tp
SET distance_km = mc.distance_km,
    base_fare_per_seat = ROUND((mc.distance_km * mc.per_km_rate)::numeric, 2),
    gst_amount_per_seat = ROUND((mc.distance_km * mc.per_km_rate * (mc.gst_percentage / 100))::numeric, 2),
    price_per_seat = ROUND((mc.distance_km * mc.per_km_rate * (1 + mc.gst_percentage / 100))::numeric, 2)
FROM matched_config mc
WHERE tp.id = mc.id;
