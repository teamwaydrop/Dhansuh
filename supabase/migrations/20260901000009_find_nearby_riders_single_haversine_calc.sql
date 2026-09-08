-- Migration: compute the Haversine distance ONCE per candidate row in find_nearby_riders()
-- instead of twice (WHERE radius predicate + SELECT distance_km), reusing the single computed
-- value for filtering, ordering, and the returned column.
--
-- ROOT CAUSE (find_nearby_riders forensic performance audit): the live definition
-- (20260825000000_payment_pending_busy_state_fix.sql) writes out the identical Haversine
-- expression twice -- once (unrounded) in the WHERE clause's `<= p_radius_km` check, and again
-- (rounded to 2 decimals) in the SELECT list as `distance_km`. PostgreSQL does not perform
-- cross-clause common-subexpression elimination between a WHERE predicate and a SELECT-list
-- expression for non-constant per-row computations -- these are evaluated in separate phases
-- (filter, then projection) of the scan, so every otherwise-eligible candidate row pays for the
-- full trig formula (radians/cos/sin/acos) twice.
--
-- FIX: restructure into a CTE that computes the raw (unrounded) distance exactly once per row,
-- alongside every column already being selected. The outer query then:
--   - filters on the CTE's raw (unrounded) distance against p_radius_km -- IDENTICAL semantics to
--     the current unrounded WHERE-clause comparison (not "improved" to compare the rounded value,
--     which would be a behavior change).
--   - rounds that same value once for the returned distance_km column, exactly as before
--     (ROUND(..., 2), same precision).
--   - orders by the SELECT list's distance_km alias, exactly as the current definition does
--     (PostgreSQL resolves an ORDER BY item matching an output alias to that alias's computed
--     value, i.e. the rounded value -- this migration preserves that exact existing behavior
--     rather than switching to sorting by the raw value).
--   - applies LIMIT last, in the same position relative to ORDER BY as before.
--
-- SCOPE: every eligibility predicate (account_status, service_mode, null-coordinate guard,
-- self-exclusion, tax-due/COD-limit/active-trip checks, KYC status/activation, staleness window,
-- vehicle/weight/order-type matching rules) is moved into the CTE's WHERE clause completely
-- unchanged -- same conditions, same order, same operators, not one rule added, removed, or
-- reordered relative to another. The function's parameters, RETURNS TABLE shape, LANGUAGE plpgsql,
-- SECURITY DEFINER, search_path, the order-fetch SELECT, the auth.uid() ownership guard, the
-- get_required_service_mode()/dispatch_config lookups, and every returned column are untouched.
-- No PostGIS/geospatial index work, no exclusion-list changes, no dispatch logic, and no other
-- migration/function (including the just-added STABLE marking on is_rider_blocked_by_cod_limit()
-- in 20260901000008, which this migration does not redefine or otherwise touch) is affected.
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
    WITH candidates AS (
        SELECT
            r.id AS rider_id,
            r.user_id,
            rk.full_name,
            rk.vehicle_type::text AS vehicle_type,
            rk.vehicle_number,
            r.current_lat,
            r.current_lng,
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
            ) AS raw_distance_km
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
    )
    SELECT
        candidates.rider_id,
        candidates.user_id,
        candidates.full_name,
        candidates.vehicle_type,
        candidates.vehicle_number,
        candidates.current_lat,
        candidates.current_lng,
        ROUND(candidates.raw_distance_km::numeric, 2) AS distance_km
    FROM candidates
    WHERE candidates.raw_distance_km <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$function$;
