-- Migration: Canonical "which Partner Service Mode does this order require" function.
-- Date: 2026-07-18
--
-- Single source of truth reused by the dispatch functions, the guard
-- triggers, and (conceptually) mirrored by the existing client-side
-- TransportOrder.flowType/isIntercity logic in
-- lib/models/transport_order.dart, so the local/intercity classification
-- rule lives in exactly one place instead of being copy-pasted across
-- multiple SQL functions.
--
-- Preserves the existing (pre-this-change) behavior of treating a plain
-- 'ride' order over 20km as intercity, exactly as
-- lib/models/transport_order.dart's OrderFlowType getter and
-- intercity_tracking_screen.dart / intercity_rides_screen.dart already do
-- today — this migration does not change that threshold, only centralizes
-- it for reuse by the new service-mode enforcement.

CREATE OR REPLACE FUNCTION public.get_required_service_mode(
    p_order_type text,
    p_distance_meters integer
)
RETURNS public.partner_service_mode_enum
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
    SELECT CASE
        WHEN p_order_type IN ('intercity_ride', 'intercity_parcel') THEN 'intercity'::public.partner_service_mode_enum
        WHEN p_order_type = 'ride' AND COALESCE(p_distance_meters, 0) > 20000 THEN 'intercity'::public.partner_service_mode_enum
        ELSE 'local'::public.partner_service_mode_enum
    END;
$$;

COMMENT ON FUNCTION public.get_required_service_mode(text, integer) IS
    'Canonical mapping from an order''s order_type/distance to the Partner Service Mode required to be dispatched/assigned to it. Reused by find_nearby_riders, assign_nearby_searching_orders_to_rider, and the rider_assignments/orders service-mode guard triggers.';
