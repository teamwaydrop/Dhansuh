-- Migration: let find_nearby_riders() skip already-excluded riders BEFORE doing eligibility/
-- KYC/tax/COD/active-trip/Haversine work for them, instead of doing that work for every candidate
-- and having start-dispatch discard already-excluded riders afterward in JavaScript.
--
-- ROOT CAUSE (P2 dispatch repeated-rider-scan forensic audit): start-dispatch calls
-- find_nearby_riders() once per dispatch round. The function has no notion of which riders were
-- already offered/rejected/expired for this order in a prior round -- it re-evaluates every
-- eligibility predicate and the Haversine distance for every online, in-radius, in-mode rider each
-- time, including ones start-dispatch already knows (from rider_assignments, fetched AFTER the RPC
-- returns) it will immediately discard. From round 2 onward this repeats full eligibility work for
-- riders that cannot possibly be re-offered this round.
--
-- FIX: add ONE new optional parameter, p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[], and one
-- early WHERE predicate excluding those rider IDs before the tax-due/COD-limit/KYC/active-trip
-- checks and the Haversine calculation run. The caller (start-dispatch) now computes the exact same
-- fare-aware and hidden_until-aware exclusion set it already computed before -- byte-for-byte
-- identical rules, just moved earlier in the function -- and passes the resulting rider_id list in.
--
-- BEHAVIOR PRESERVATION:
--   - The new parameter defaults to an empty array. An empty array excludes nothing, so any caller
--     that does not pass it (every existing caller except start-dispatch: the passenger-facing
--     nearby-rider-count screens in ride_searching_screen.dart / parcel_searching_screen.dart) gets
--     results byte-for-byte identical to before this migration.
--   - No eligibility predicate, radius semantics, Haversine formula, sort order, LIMIT, returned
--     columns, SECURITY DEFINER, search_path, or auth.uid() ownership guard is changed. The single-
--     Haversine-calculation CTE structure from 20260901000009 is otherwise untouched.
--   - This migration does NOT implement any fare/hidden_until re-eligibility logic in SQL. That
--     logic remains exclusively in start-dispatch's JavaScript, exactly as before -- this function
--     only ever receives an already-fully-computed exclusion list and applies a plain `!= ALL(...)`
--     membership check.
CREATE OR REPLACE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer, p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[])
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
            AND NOT (r.id = ANY(p_excluded_rider_ids))
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
