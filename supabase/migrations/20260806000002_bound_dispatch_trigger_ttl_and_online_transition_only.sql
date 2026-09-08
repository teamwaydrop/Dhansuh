-- Migration: Bound assign_nearby_searching_orders_to_rider() to (a) never re-offer an order past
-- its configured search lifetime, and (b) fire only on a genuine online-transition instead of on
-- every location heartbeat.
-- Date: 2026-08-02
--
-- ROOT CAUSE (production incident investigation, "old ride requests reaching online riders" +
-- "progressive slowdown during long testing sessions"):
--
-- 1. STALENESS: the function's candidate loop (`SELECT ... FROM public.orders o WHERE
--    o.order_status = 'searching' AND o.user_id != NEW.user_id`, unchanged since
--    20260531000003_fix_find_nearby_riders.sql) has never had any bound on the order's age. Any
--    order still `order_status = 'searching'` -- 10 seconds old or 10 hours old -- is a candidate
--    every single time this trigger fires, and for a rider with an `'expired'` assignment on that
--    order whose fare has since increased, the function resets it straight back to `'sent'` with a
--    fresh `sent_at`/`expires_at` (unchanged below, lines ~582-619 of the prior definition) --
--    indistinguishable from a brand-new request on the rider's screen.
--
-- 2. UNBOUNDED FIRING FREQUENCY: the live trigger definition
--    (20260601000006_convert_timestamps_to_timestamptz.sql:32-44) fires on
--    `UPDATE OF account_status, current_lat, current_lng, last_location_updated_at`, gated by a WHEN
--    clause that also fires on any lat/lng/last_location_updated_at change while already online --
--    not just the online transition. `LocationCacheService`'s heartbeat
--    (`lib/core/services/location/location_cache_service.dart:82,492-495,642-653`) writes
--    `last_location_updated_at` unconditionally at least every 30 seconds for every online rider
--    (more often while moving), so this trigger's full O(searching orders) loop, with a per-order
--    haversine computation, re-runs for every online rider roughly every 30 seconds for as long as
--    they stay online -- for the entire remaining session. Since nothing previously expired stale
--    `'searching'` orders (see 20260806000004_add_expire_stale_searching_orders_and_schedule.sql,
--    applied alongside this migration), the candidate set this loop scans only grows across a
--    multi-ride testing session, making each of these recurring heartbeat-driven scans progressively
--    more expensive -- the direct mechanical explanation for "fine for the first few rides, slower
--    after several."
--
-- FIX, part A (this function): add an order-age bound sourced from the SAME `dispatch_config` row
-- already queried for round_2_radius_km/rider_location_stale_sec/rider_response_timeout_sec, using
-- the existing `max_search_duration_sec` column (already the authoritative search-lifetime value
-- start-dispatch's own active dispatch loop uses to decide when to give up, see
-- 20260806000004_add_expire_stale_searching_orders_and_schedule.sql). This makes the guarantee
-- "an order can never be offered again once its search lifetime has expired" hold INSIDE this
-- trigger itself, independent of the cron backstop in the sibling migration below -- correct even if
-- the cron never runs (extension disabled, job removed, etc.). No other predicate, matching rule,
-- fare-eligibility, self-match exclusion, or tax-due gate is changed -- every other line is
-- preserved byte-for-byte from the 20260726000004_government_tax_due_functions.sql definition.
--
-- FIX, part B (the trigger definition): remove current_lat/current_lng/last_location_updated_at
-- from `UPDATE OF` and the WHEN clause, so this trigger fires ONLY on a genuine transition into
-- 'online'. This does not regress matching: while an order is genuinely still within its search
-- window, it is under CONTINUOUS active re-matching by start-dispatch's own loop
-- (supabase/functions/start-dispatch/index.ts), which re-queries find_nearby_riders() with the
-- rider's live current_lat/current_lng every 2-15 seconds for the order's entire search lifetime --
-- strictly more frequent and more precise than a 30-second heartbeat rescan ever was. The only
-- riders this heartbeat-triggered rescan ever mattered for are riders who go online (or come back
-- online); that path is fully preserved by the WHEN clause's remaining
-- `NEW.account_status = 'online' AND OLD.account_status IS DISTINCT FROM 'online'` condition.

CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
RETURNS TRIGGER AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_max_search_duration_sec integer;
    v_existing_id uuid;
    v_existing_status text;
    v_rider_vehicle text;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- GOVERNMENT TAX DUE: a blocked rider receives no new assignments through this trigger either.
    IF public.is_rider_blocked_by_tax_due(NEW.id) THEN
        RETURN NEW;
    END IF;

    SELECT
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120),
        COALESCE(max_search_duration_sec, 900)
    INTO
        v_radius_km,
        v_stale_sec,
        v_timeout_sec,
        v_max_search_duration_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);
    v_max_search_duration_sec := COALESCE(v_max_search_duration_sec, 900);

    SELECT COALESCE(rk.vehicle_type::text, '') INTO v_rider_vehicle
    FROM public.rider_kyc rk
    WHERE rk.user_id = NEW.user_id
    LIMIT 1;

    FOR v_order IN (
        SELECT
            o.id,
            o.pickup_lat,
            o.pickup_lng,
            o.vehicle_type::text AS vehicle_type,
            o.order_type::text AS order_type,
            o.rider_earning,
            o.distance_meters,
            COALESCE(
                o.actual_weight_kg,
                COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
            )::double precision AS weight_kg
        FROM public.orders o
        WHERE o.order_status = 'searching'
          AND o.user_id != NEW.user_id
          -- STALENESS GUARD (new): never a candidate for (re-)offering once the order has been
          -- searching longer than the platform's configured search lifetime. Matches the
          -- boundary start-dispatch's own active loop already uses to decide when to stop, so a
          -- rider going online never sees an order the active dispatch loop has already given up
          -- on.
          AND o.created_at >= (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
    ) LOOP
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(NEW.current_lat))
                * cos(
                    radians(NEW.current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(NEW.current_lat))
            , -1.0), 1.0)
        );

        IF v_dist_km <= v_radius_km
           AND public.get_required_service_mode(v_order.order_type, v_order.distance_meters) = NEW.service_mode
           AND (
            ((v_order.order_type = 'ride' OR v_order.order_type = 'intercity_ride' OR v_order.order_type = 'intercity') AND
             v_rider_vehicle = v_order.vehicle_type)
            OR
            (v_order.order_type = 'ride_sharing' AND v_rider_vehicle IN ('auto', 'cab'))
            OR
            (
                (v_order.order_type = 'local_parcel' OR v_order.order_type LIKE '%parcel%' OR v_order.order_type LIKE '%delivery%')
                AND v_order.order_type != 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle = 'auto')
                )
            )
            OR
            (
                v_order.order_type = 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle IN ('auto', 'cab'))
                )
            )
            OR
            (v_order.order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order.order_type NOT LIKE '%parcel%' AND v_order.order_type NOT LIKE '%delivery%')
        ) THEN
            v_existing_id := NULL;
            v_existing_status := NULL;

            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id
              AND rider_id = NEW.id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    INSERT INTO public.rider_assignments (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        distance_km,
                        estimated_earnings,
                        sent_at,
                        expires_at,
                        last_seen_at,
                        last_seen_fare
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    INSERT INTO public.order_assignment_logs (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        rider_distance_km,
                        estimated_pickup_time_min,
                        sent_at
                    ) VALUES (
                        v_order.id,
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

-- Narrow the trigger to fire only on a genuine online-transition (see header, FIX part B).
DROP TRIGGER IF EXISTS trigger_assign_nearby_orders ON public.riders;
CREATE TRIGGER trigger_assign_nearby_orders
AFTER UPDATE OF account_status ON public.riders
FOR EACH ROW
WHEN (
    NEW.account_status = 'online'
    AND OLD.account_status IS DISTINCT FROM 'online'
)
EXECUTE FUNCTION public.assign_nearby_searching_orders_to_rider();
