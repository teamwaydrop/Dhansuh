-- Migration: replace find_nearby_riders()'s per-candidate is_rider_blocked_by_tax_due(r.id) /
-- is_rider_blocked_by_cod_limit(r.id) calls with direct comparisons against columns the function
-- already has in scope on `r`, instead of each call re-querying `riders` by primary key for data
-- the outer scan already read.
--
-- ROOT CAUSE (P6/P6.1 find_nearby_riders forensic performance audit, confirmed against live
-- production via EXPLAIN ANALYZE): is_rider_blocked_by_tax_due(p_rider_id) and
-- is_rider_blocked_by_cod_limit(p_rider_id) (20260726000004, 20260808000002) each run their own
-- `SELECT ... FROM riders WHERE id = p_rider_id` internally. When called as
-- `is_rider_blocked_by_tax_due(r.id)` / `is_rider_blocked_by_cod_limit(r.id)` from inside this
-- function's own `FROM riders r` scan, that is a redundant self-lookup: `r` already IS that exact
-- row, same primary key, same MVCC snapshot within the same statement. A real production EXPLAIN
-- (ANALYZE, BUFFERS) run against the reconstructed inner query showed 643 of 651 total buffer hits
-- concentrated in exactly this filter step, on a `riders` table with only 22 live rows -- i.e. the
-- redundant lookups, not sequential scanning or the Haversine calculation, are the measured cost
-- driver. is_rider_blocked_by_tax_due() additionally calls get_active_tax_due_threshold() (a
-- government_tax_config lookup) fresh on every invocation; that value does not depend on the row
-- being filtered, so it is fetched exactly once here instead, mirroring the existing
-- v_stale_sec/dispatch_config pattern already used a few lines above in this same function.
--
-- EQUIVALENCE (full truth-table verified against live schema, not assumed):
--   - riders.government_tax_due_balance is NOT NULL (confirmed via information_schema.columns on
--     the linked production project) -- is_rider_blocked_by_tax_due()'s
--     `COALESCE(government_tax_due_balance, 0)` is therefore the identity function on that column
--     for every existing row, so `r.government_tax_due_balance < v_tax_due_threshold` is the exact
--     boolean negation of `is_rider_blocked_by_tax_due(r.id)` (`>= threshold`) for every possible
--     value, with v_tax_due_threshold populated from the identical get_active_tax_due_threshold()
--     call the original code used, just hoisted once instead of once per row. get_active_tax_due_
--     threshold() is STABLE, which guarantees one consistent result across the whole statement's
--     snapshot regardless of whether it's called once or once per row -- hoisting it changes
--     nothing about the value observed.
--   - riders.cod_pending_amount and riders.cod_limit ARE nullable in the live schema, so
--     `COALESCE(r.cod_pending_amount, 0) < COALESCE(r.cod_limit, 500)` reproduces
--     is_rider_blocked_by_cod_limit()'s exact `COALESCE(cod_pending_amount, 0) >=
--     COALESCE(cod_limit, 500)` fallback behavior verbatim (same defaults, same >= direction,
--     inverted to < for the eligibility predicate this replaces `NOT is_rider_blocked_by_cod_limit`
--     with).
--
-- SCOPE: only this function's body changes. is_rider_blocked_by_tax_due(),
-- is_rider_blocked_by_cod_limit(), and get_active_tax_due_threshold() are NOT modified by this
-- migration and remain exactly as-is for their other callers (assign_nearby_searching_orders_to_
-- rider() and other triggers/RPCs keyed on NEW.id/v_rider.id/p_rider_id, and accept-order's Edge
-- Function RPC calls) -- none of which are touched here. No other eligibility predicate, the
-- Haversine formula, the excluded-rider-ids parameter/check, service-mode matching, KYC/activation
-- checks, staleness rules, active-trip exclusion, ORDER BY, LIMIT, the function signature, the
-- returned columns, SECURITY DEFINER, or search_path is changed. The single-Haversine-calculation
-- CTE structure from 20260901000009 and the excluded-rider-ids early filter from 20260901000010 are
-- otherwise untouched.
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
    v_tax_due_threshold numeric;
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

    -- Fetched once per call, not once per candidate row -- see migration header. Identical source
    -- (get_active_tax_due_threshold()) and identical STABLE snapshot guarantee as the previous
    -- per-row calls inside is_rider_blocked_by_tax_due().
    SELECT public.get_active_tax_due_threshold()
    INTO v_tax_due_threshold;

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
            AND r.government_tax_due_balance < v_tax_due_threshold
            AND COALESCE(r.cod_pending_amount, 0) < COALESCE(r.cod_limit, 500)
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
