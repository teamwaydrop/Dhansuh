-- Migration: fix "0 active partners nearby" shown to a passenger whose Drop Partner was
-- physically co-located, online, and dispatch-eligible.
-- Date: 2026-07-29
--
-- ROOT CAUSE (confirmed by code inspection): find_nearby_riders() (base logic:
-- 20260718000010_enforce_service_mode_in_dispatch_functions.sql, last touched
-- 20260726000004_government_tax_due_functions.sql to add the government-tax-due gate) is a plain
-- `LANGUAGE plpgsql` function -- NOT `SECURITY DEFINER`, unlike every sibling function added in
-- that same migration (apply_order_government_tax, is_rider_blocked_by_tax_due,
-- assign_nearby_searching_orders_to_rider, accept_intercity_request). start-dispatch/accept-order
-- call it using the service-role key, which bypasses RLS entirely regardless of the function's own
-- security context. The passenger's own "X active partners nearby" text
-- (ride_searching_screen.dart / parcel_searching_screen.dart / intercity_searching_screen.dart)
-- calls this SAME RPC directly via `supabase.rpc('find_nearby_riders', ...)` under their own
-- `authenticated` JWT -- so, uniquely for this one caller, every table read inside the function
-- (orders, riders, rider_kyc, dispatch_config) runs under SECURITY INVOKER, subject to that
-- passenger's own RLS policies instead of the same privileged context every other caller gets.
-- This is the structural reason the identical predicate can return zero rows for a passenger
-- while the exact same function, called by start-dispatch, matches the same rider moments later.
--
-- FIX: make this SECURITY DEFINER, exactly like its sibling dispatch functions, so a
-- passenger-invoked call is guaranteed to see precisely what a service-role-invoked call sees --
-- one canonical eligibility predicate, not two privilege contexts for the same query. Making it
-- SECURITY DEFINER without any other change would ALSO remove RLS's previous (incidental) side
-- effect of only ever letting a passenger query their own order's candidates -- p_order_id itself
-- was never validated against the caller. An explicit ownership check is added below to close
-- exactly that gap: an authenticated (non-service-role) caller may only query nearby riders for an
-- order they themselves created; service-role callers (dispatch/matching backend) are unaffected.
-- This must not expose one passenger's nearby-Drop-Partner data (name, vehicle, live location) to
-- an unrelated caller.
--
-- Every other line of the function (eligibility predicate, radius/distance formula, vehicle/KYC/
-- activation/tax-due/busy-order rules) is preserved byte-for-byte -- this migration changes ONLY
-- the security context and adds the ownership guard, nothing else.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.find_nearby_riders(
    p_order_id uuid,
    p_pickup_lat double precision,
    p_pickup_lng double precision,
    p_radius_km double precision,
    p_limit integer
)
RETURNS TABLE(
    rider_id uuid,
    user_id uuid,
    full_name text,
    vehicle_type text,
    vehicle_number text,
    current_lat double precision,
    current_lng double precision,
    distance_km numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

    -- AUTHORIZATION GUARD (new): SECURITY DEFINER above means this no longer inherits RLS's
    -- previous incidental protection -- an authenticated (non-service-role) caller must be this
    -- order's own creator. auth.uid() is NULL for the service-role key (no JWT), so
    -- start-dispatch/accept-order/match-intercity-riders are entirely unaffected by this check.
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
        AND NOT EXISTS (
            SELECT 1
            FROM orders o
            WHERE
                o.rider_id = r.id
                AND o.order_status IN (
                    'accepted',
                    'rider_arrived',
                    'picked_up',
                    'ongoing'
                )
        )
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
$$;

GRANT EXECUTE ON FUNCTION public.find_nearby_riders(uuid, double precision, double precision, double precision, integer) TO authenticated, service_role;
