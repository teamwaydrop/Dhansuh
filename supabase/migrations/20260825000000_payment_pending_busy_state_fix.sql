-- Migration: treat payment_pending as BUSY throughout local-dispatch rider matching, consistent
-- with the rest of the codebase.
--
-- ROOT CAUSE (confirmed via read-only production forensics, not assumed): the codebase already has
-- a canonical "is this rider busy" predicate, rider_is_on_active_trip() (20260720000004), which
-- correctly includes payment_pending -- and it IS already followed correctly by
-- RiderHomeTab._isOrderActivelyBusy() (lib/features/rider/home/rider_home_tab.dart) and by one
-- inline check in update-order-status/index.ts. But find_nearby_riders() originally called
-- rider_is_on_active_trip() too (20260720000004), and was silently reverted to a narrower, inline
-- 4-state list six days later by 20260726000004_government_tax_due_functions.sql -- a migration
-- entirely about adding tax-due checks, which appears to have re-created find_nearby_riders() from
-- an older base by accident (no comment anywhere acknowledges a busy-check change). That narrower
-- list was then independently duplicated into trigger_assign_nearby_orders_on_rider_freed's WHEN
-- clause, prevent_local_ride_assignment_to_busy_rider, and accept-order/index.ts's own inline
-- alwaysActiveStatuses (whose own comment claims to "mirror" rider_is_on_active_trip() but never
-- actually calls it) -- none of which include payment_pending. Net effect, confirmed via a live
-- controlled device test: a rider sitting in payment_pending on Ride A could be offered and could
-- accept Ride B, and completing Ride A's ongoing->payment_pending transition (not its actual
-- payment_pending->completed/delivered finish) was what fired the rider-freed rematch.
--
-- FIX: payment_pending becomes part of the local-dispatch blocking set everywhere it was missing,
-- and find_nearby_riders() has its inline list replaced with the canonical
-- rider_is_on_active_trip() call it originally used -- restoring the pre-20260726000004 behavior
-- instead of re-inventing a fifth copy of the same list. Only the busy-check clause changes in each
-- function below; every other clause (radius, vehicle/weight matching, service_mode, tax/COD
-- gating, KYC, staleness) is reproduced byte-for-byte from the live definition.
--
-- SCOPE: local ride/parcel dispatch matching only. Payment settlement logic itself
-- (payment_pending->completed/delivered guards, Cashfree/Personal UPI/cash resolution in
-- update-order-status/index.ts) is completely untouched -- this migration only changes WHO can be
-- newly assigned a searching order while their own current order is at a given status, never how an
-- order's own payment/completion is confirmed. prevent_local_ride_assignment_to_busy_rider's scope
-- (order_type='ride' only) is intentionally left as-is -- the parcel-side guard gap identified
-- during this investigation is a separate, pre-existing issue and is documented, not fixed, here.

-- =====================================================================================
-- 1. trigger_assign_nearby_orders_on_rider_freed -- payment_pending joins the blocking set on
--    BOTH sides of the WHEN clause. This has two effects, both intended:
--      - ongoing -> payment_pending no longer fires a rematch (NEW is now itself blocking).
--      - payment_pending -> completed and payment_pending -> delivered now fire a rematch (OLD was
--        blocking, NEW isn't) -- previously neither did, since OLD='payment_pending' was already
--        being treated as non-blocking and so never satisfied "OLD IN blocking set" either.
--    The underlying function, assign_nearby_searching_orders_on_rider_freed(), is unchanged --
--    it never referenced order_status itself, only the WHEN clause decides when it runs.
-- =====================================================================================
DROP TRIGGER IF EXISTS trigger_assign_nearby_orders_on_rider_freed ON public.orders;
CREATE TRIGGER trigger_assign_nearby_orders_on_rider_freed
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
WHEN (
    OLD.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
    AND NEW.order_status NOT IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
    AND NEW.rider_id IS NOT NULL
)
EXECUTE FUNCTION public.assign_nearby_searching_orders_on_rider_freed();

-- =====================================================================================
-- 2. prevent_local_ride_assignment_to_busy_rider -- payment_pending added to the blocking-order
--    EXISTS check. Scope is deliberately unchanged otherwise: still order_type='ride' only, still
--    distance_meters <= 20000 (the parcel-side gap is a separate, documented issue, not fixed
--    here).
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.prevent_local_ride_assignment_to_busy_rider()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_new_order_type text;
    v_new_distance integer;
BEGIN
    IF NEW.assignment_status IS DISTINCT FROM 'sent' THEN
        RETURN NEW;
    END IF;

    SELECT o.order_type::text, o.distance_meters
    INTO v_new_order_type, v_new_distance
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    -- Only local rides are in scope for this guard.
    IF v_new_order_type IS DISTINCT FROM 'ride' OR COALESCE(v_new_distance, 0) > 20000 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.orders bo
        WHERE bo.rider_id = NEW.rider_id
          AND bo.id != NEW.order_id
          AND bo.order_type = 'ride'
          AND COALESCE(bo.distance_meters, 0) <= 20000
          AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
    ) THEN
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$function$;

-- =====================================================================================
-- 3. find_nearby_riders -- restores the rider_is_on_active_trip() busy check it originally had in
--    20260720000004, replacing the narrower inline NOT EXISTS list it was accidentally reverted to
--    in 20260726000004. Every other clause below is reproduced byte-for-byte from the live
--    definition -- radius, vehicle/weight/service-mode matching, tax/COD gating, KYC/activation
--    status, staleness window, and the SECURITY DEFINER authorization guard are all unchanged.
--
--    Verified compatible with every current caller: start-dispatch (order-side dispatch worker)
--    and match-intercity-riders both call this RPC as service_role (auth.uid() IS NULL, so the
--    authorization guard above is unaffected) and only ever consume the returned rider list --
--    neither assumes anything about which specific order_status values are excluded internally.
--    One deliberate behavior change ships as part of restoring the canonical predicate: an
--    intercity/long-distance order sitting at 'accepted' with trip_started_at still null (rider
--    "Waiting for Travel Day") is no longer treated as busy here, matching accept-order's own
--    existing carve-out for the exact same case (accept-order/index.ts, pre-existing) -- these two
--    already-existing systems were themselves inconsistent with each other before this fix; this
--    restores consistency rather than introducing a new rule.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer)
RETURNS TABLE(rider_id uuid, user_id uuid, full_name text, vehicle_type text, vehicle_number text, current_lat double precision, current_lng double precision, distance_km numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
BEGIN
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id,
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
        )::double precision,
        o.distance_meters
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id,
        v_weight_kg,
        v_distance_meters
    FROM orders o
    WHERE o.id = p_order_id;

    -- AUTHORIZATION GUARD: SECURITY DEFINER means this no longer inherits RLS's previous
    -- incidental protection -- an authenticated (non-service-role) caller must be this order's own
    -- creator. auth.uid() is NULL for the service-role key (no JWT), so start-dispatch/accept-order/
    -- match-intercity-riders are entirely unaffected by this check.
    IF auth.uid() IS NOT NULL AND (v_creator_user_id IS NULL OR auth.uid() != v_creator_user_id) THEN
        RETURN;
    END IF;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    RETURN QUERY
    SELECT
        r.id AS rider_id,
        r.user_id,
        rk.full_name,
        rk.vehicle_type::text AS vehicle_type,
        rk.vehicle_number,
        r.current_lat,
        r.current_lng,
        ROUND(
            (
                6371 * acos(
                    LEAST(GREATEST(
                        cos(radians(p_pickup_lat))
                        * cos(radians(r.current_lat))
                        * cos(
                            radians(r.current_lng)
                            - radians(p_pickup_lng)
                        )
                        + sin(radians(p_pickup_lat))
                        * sin(radians(r.current_lat))
                    , -1.0), 1.0)
                )
            )::numeric,
            2
        ) AS distance_km
    FROM riders r
    INNER JOIN rider_kyc rk
        ON rk.user_id = r.user_id
    WHERE
        r.account_status = 'online'
        AND r.service_mode = v_required_mode
        AND r.current_lat IS NOT NULL
        AND r.current_lng IS NOT NULL
        AND r.user_id != v_creator_user_id
        AND NOT public.is_rider_blocked_by_tax_due(r.id)
        AND NOT public.is_rider_blocked_by_cod_limit(r.id)
        AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
        AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
        AND (
            r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
            OR
            r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
            OR
            r.last_location_updated_at IS NULL
        )
        AND (
            ((v_order_type = 'ride' OR v_order_type = 'intercity_ride' OR v_order_type = 'intercity') AND
             rk.vehicle_type::text = v_vehicle_type)
            OR
            (v_order_type = 'ride_sharing' AND rk.vehicle_type::text IN ('auto', 'cab'))
            OR
            (
                (v_order_type = 'local_parcel' OR v_order_type LIKE '%parcel%' OR v_order_type LIKE '%delivery%')
                AND v_order_type != 'intercity_parcel'
                AND
                (
                    (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                    OR
                    (v_weight_kg >= 10.0 AND rk.vehicle_type::text = 'auto')
                )
            )
            OR
            (
                v_order_type = 'intercity_parcel'
                AND
                (
                    (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                    OR
                    (v_weight_kg >= 10.0 AND rk.vehicle_type::text IN ('auto', 'cab'))
                )
            )
            OR
            (v_order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order_type NOT LIKE '%parcel%' AND v_order_type NOT LIKE '%delivery%')
        )
        AND NOT public.rider_is_on_active_trip(r.id)
        AND (
            6371 * acos(
                LEAST(GREATEST(
                    cos(radians(p_pickup_lat))
                    * cos(radians(r.current_lat))
                    * cos(
                        radians(r.current_lng)
                        - radians(p_pickup_lng)
                    )
                    + sin(radians(p_pickup_lat))
                    * sin(radians(r.current_lat))
                , -1.0), 1.0)
            )
        ) <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$function$;
