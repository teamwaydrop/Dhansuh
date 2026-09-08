-- Migration: re-run opportunistic dispatch matching the moment a rider's active order leaves the
-- "blocking" set (completes, is delivered, or is cancelled) -- not just when the rider's own
-- account_status transitions into 'online'.
-- Date: 2026-08-08
--
-- BUG: "Local Ride partners stop receiving new ride requests after completing a ride. Rider stays
-- online; no new requests arrive; only a manual offline->online toggle fixes it."
--
-- ROOT CAUSE (verified from source and the live database, not assumed):
--   - Neither accept-order/index.ts nor update-order-status/index.ts ever writes
--     riders.account_status (confirmed by grep -- accept-order only READS it, at line ~200, to
--     check the rider is online before allowing acceptance). A rider's account_status is written
--     exactly once per "go online" action and stays 'online' for the rest of that session,
--     including through accept -> rider_arrived -> picked_up -> ongoing -> completed. Busy-ness is
--     determined entirely by the EXISTENCE of an order in an active status
--     (find_nearby_riders()'s own `NOT EXISTS (... order_status IN ('accepted','rider_arrived',
--     'picked_up','ongoing'))` clause, confirmed against the live function definition), never by
--     toggling account_status.
--   - trigger_assign_nearby_orders (20260806000002_bound_dispatch_trigger_ttl_and_online_transition
--     _only.sql) intentionally fires ONLY on a genuine transition INTO 'online'
--     (`WHEN (NEW.account_status = 'online' AND OLD.account_status IS DISTINCT FROM 'online')`) --
--     a deliberate, correct scalability fix from the prior dispatch-staleness investigation, which
--     eliminated an O(online riders x searching orders) rescan that used to run on every 30-second
--     GPS heartbeat. That fix did not anticipate this consequence: since account_status never
--     changes again for the rest of an online session, this trigger -- the ONLY thing that
--     opportunistically re-offers a currently-searching order to a rider who wasn't free when that
--     order started searching -- never fires again for that rider after their first "go online",
--     for the ENTIRE remainder of the session. Completing a ride does not create any event this
--     trigger listens for. The only action that does is exactly what the workaround describes:
--     toggling offline then online, which is a genuine account_status transition.
--   - start-dispatch's own active per-order dispatch loop (supabase/functions/start-dispatch/
--     index.ts) is independent of this trigger and keeps re-querying find_nearby_riders() every
--     2-15 seconds for as long as an individual order is still within its own search window -- so
--     it can still opportunistically catch a newly-freed rider for orders whose worker is still
--     actively running. This trigger is specifically what covers every other case: orders whose
--     active worker already exhausted its rounds/timed out while the rider was busy, or any gap in
--     that chain -- which is exactly the gap the reported bug falls into.
--
-- FIX: extract the existing per-rider matching loop (byte-for-byte unchanged: same order-age TTL
-- guard, same radius/vehicle/weight/service-mode eligibility rules, same expired/rejected re-offer
-- logic, same rider_assignments/order_assignment_logs writes) into a shared function parameterized
-- on rider identity/location/service_mode instead of reading NEW directly. The existing riders-side
-- trigger now just calls it (zero behavior change -- verified byte-for-byte identical below). A NEW,
-- narrowly-scoped trigger on public.orders calls the SAME shared function exactly once, only when a
-- rider's order transitts OUT of the blocking set defined above -- mirroring find_nearby_riders()'s
-- own exclusion predicate exactly (fires on the precise transition where that predicate flips from
-- "blocked" to "free" for this rider), so it is correct by construction relative to the eligibility
-- rule it exists to satisfy. Order completions/cancellations are comparatively rare, one-shot events
-- (not a 30-second recurring timer), so this reintroduces none of the heartbeat-driven scaling
-- problem the prior fix eliminated.
--
-- SCOPE: intentionally not restricted to order_type = 'ride' or to any particular vehicle/service
-- mode -- the shared matching function's own existing eligibility rules already handle every order
-- type exactly as the pre-existing riders-side trigger always has. Restricting this new trigger by
-- order_type would be an arbitrary, inconsistent special case relative to how that trigger already
-- behaves for every other order type today.

-- =====================================================================
-- 1. Shared matching core, extracted verbatim from the current live
--    assign_nearby_searching_orders_to_rider() body -- no eligibility rule, matching condition, or
--    write changed in any way, only parameterized so it can be called from more than one trigger.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_core(
    p_rider_id uuid,
    p_rider_user_id uuid,
    p_current_lat double precision,
    p_current_lng double precision,
    p_service_mode public.partner_service_mode_enum
)
RETURNS void AS $$
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
    IF p_current_lat IS NULL OR p_current_lng IS NULL THEN
        RETURN;
    END IF;

    -- GOVERNMENT TAX DUE: a blocked rider receives no new assignments through this path either.
    IF public.is_rider_blocked_by_tax_due(p_rider_id) THEN
        RETURN;
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
    WHERE rk.user_id = p_rider_user_id
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
          AND o.user_id != p_rider_user_id
          -- STALENESS GUARD: never a candidate for (re-)offering once the order has been searching
          -- longer than the platform's configured search lifetime.
          AND o.created_at >= (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
    ) LOOP
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(p_current_lat))
                * cos(
                    radians(p_current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(p_current_lat))
            , -1.0), 1.0)
        );

        IF v_dist_km <= v_radius_km
           AND public.get_required_service_mode(v_order.order_type, v_order.distance_meters) = p_service_mode
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
              AND rider_id = p_rider_id
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
                        p_rider_id,
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
                        p_rider_id,
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
                            p_rider_id,
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
                            p_rider_id,
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
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 2. Existing riders-side trigger function now just delegates to the shared core -- behavior is
--    byte-for-byte identical to before (same NULL-lat/lng early return, same tax-due gate, same
--    parameters derived from NEW).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        NEW.id,
        NEW.user_id,
        NEW.current_lat,
        NEW.current_lng,
        NEW.service_mode
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 3. NEW: orders-side trigger. Fires once, only on the exact transition where
--    find_nearby_riders()'s own busy-exclusion predicate flips from "blocked" to "free" for this
--    order's rider -- i.e. completion, delivery, or cancellation of a ride/parcel that was
--    accepted/rider_arrived/picked_up/ongoing. Skips cleanly (no-op) if the rider isn't currently
--    online or has no location fix, exactly like the riders-side trigger already does.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_on_rider_freed()
RETURNS TRIGGER AS $$
DECLARE
    v_rider RECORD;
BEGIN
    IF NEW.rider_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, account_status, current_lat, current_lng, service_mode
    INTO v_rider
    FROM public.riders
    WHERE id = NEW.rider_id;

    IF NOT FOUND OR v_rider.account_status IS DISTINCT FROM 'online'::public.rider_account_status_enum THEN
        RETURN NEW;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        v_rider.id,
        v_rider.user_id,
        v_rider.current_lat,
        v_rider.current_lng,
        v_rider.service_mode
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_assign_nearby_orders_on_rider_freed ON public.orders;
CREATE TRIGGER trigger_assign_nearby_orders_on_rider_freed
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
WHEN (
    OLD.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing')
    AND NEW.order_status NOT IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing')
    AND NEW.rider_id IS NOT NULL
)
EXECUTE FUNCTION public.assign_nearby_searching_orders_on_rider_freed();
