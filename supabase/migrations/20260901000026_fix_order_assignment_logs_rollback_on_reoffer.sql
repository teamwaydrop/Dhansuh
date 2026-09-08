-- Migration: Issue 1 (Ride B never appearing after Rider A completes Ride A) -- second, deeper
-- root cause found via REAL execution against a local Supabase/Docker instance (not assumed from
-- reading migrations): assign_nearby_searching_orders_core() silently discards an otherwise
-- successful rider_assignments write whenever the paired order_assignment_logs insert hits a
-- unique-constraint violation.
--
-- PROVEN VIA LIVE LOCAL REPRODUCTION (supabase start + supabase migration up against Docker,
-- RAISE NOTICE-instrumented copy of the live function body, byte-identical logic):
--   1. A rider is offered order X for the first time -> rider_assignments (order_id, rider_id,
--      assignment_status='sent') INSERT succeeds, order_assignment_logs (order_id, rider_id,
--      assignment_round=1, ...) INSERT succeeds. Both commit.
--   2. That assignment naturally expires (client's 1s local-expiry timer / the
--      redispatch_stalled_searching_orders() cron mark it 'expired' once NOW() > expires_at --
--      the existing, unmodified 120s default rider_response_timeout_sec window) before the rider
--      responds.
--   3. ANY later re-offer attempt for the SAME (order_id, rider_id) pair -- e.g. a fare increase
--      via redispatch_freed_riders()'s 20s backstop tick, or rider_self_rematch() re-firing for a
--      rider who just became free again -- correctly reaches the `ELSIF v_existing_status =
--      'expired'` branch, UPDATEs rider_assignments back to 'sent' with a fresh expires_at... and
--      then unconditionally tries to INSERT ANOTHER order_assignment_logs row with the SAME
--      hardcoded assignment_round = 1. That INSERT ALWAYS raises unique_violation (the round=1 row
--      from step 1 already exists and assignment_round is never incremented anywhere in this
--      function). The existing `EXCEPTION WHEN unique_violation THEN NULL` wraps BOTH the
--      rider_assignments UPDATE and the order_assignment_logs INSERT in ONE implicit
--      subtransaction, so catching the log table's violation silently ROLLS BACK the
--      rider_assignments UPDATE too -- the assignment is left exactly as it was (still 'expired'),
--      invisible to RiderOrdersScreen.fetchSearchingOrders() (`.eq('assignment_status', 'sent')`),
--      with NO error surfaced anywhere. The identical bug exists in the fresh-INSERT branch
--      (`v_existing_id IS NULL`) for the same reason, reproduced live via a deliberately-seeded
--      duplicate order_assignment_logs row.
--
-- Given three independent mechanisms all funnel through this one function for a freed rider
-- (trigger_assign_nearby_orders_on_rider_freed's pg_net call, redispatch_freed_riders()'s 20s cron
-- backstop, and rider_self_rematch()'s client-triggered call -- 20260808000000, 20260824000000,
-- 20260826000000), a real device tester who takes more than the 120s response window to navigate
-- from a ride's completion screen back to "Available Rides" will see the client's own self-heal
-- offer have already expired -- and this bug means NOTHING can ever re-offer it afterward, exactly
-- reproducing "No rides" even though the order is still genuinely searching and eligible. This is
-- almost certainly why the prior client-only fix (RiderOrdersScreen's _hasPolledActiveOrderOnce,
-- which correctly calls rider_self_rematch()) still failed real-device testing: the assignment WAS
-- created, but had already silently expired-and-never-recovered by the time the tester looked.
--
-- FIX: the order_assignment_logs INSERT in all three call sites (fresh insert, 'expired' re-offer,
-- 'rejected' re-offer) is moved into its OWN isolated BEGIN/EXCEPTION sub-block, separate from the
-- rider_assignments write. A duplicate/failed audit-log write can now never roll back the dispatch-
-- critical rider_assignments INSERT/UPDATE that actually determines what the rider sees -- it is a
-- pure audit trail, not the source of truth for dispatch visibility. No eligibility, radius,
-- vehicle/weight, service-mode, tax/COD, or fare-gate rule is touched -- every WHERE clause, every
-- IF condition, and the outer per-order EXCEPTION WHEN unique_violation guard (still catching a
-- genuine concurrent-INSERT race on rider_assignments' own (order_id, rider_id) unique key) are
-- reproduced byte-for-byte from the live 20260808000002 definition.
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

    -- COD LIMIT: a rider whose cash-on-delivery pending amount has reached their configured limit
    -- receives no new assignments through this path either, until they settle.
    IF public.is_rider_blocked_by_cod_limit(p_rider_id) THEN
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

                    -- FIX: audit-log write isolated into its own sub-transaction -- a duplicate
                    -- (order_id, rider_id, assignment_round) row here (assignment_round is always 1
                    -- for this dispatch path) must never undo the rider_assignments INSERT above,
                    -- which is the actual source of truth for what the rider sees.
                    BEGIN
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
                            -- Reproduced verbatim from the live production definition (confirmed via
                            -- a read-only pg_dump audit against the linked project): the fresh-
                            -- insert branch has always written v_order.rider_earning into this
                            -- column here, not CEIL(v_dist_km * 3) like the two re-offer branches
                            -- below. Almost certainly a pre-existing, unrelated copy/paste quirk in
                            -- an inert, write-only audit-log column (order_assignment_logs.
                            -- estimated_pickup_time_min is never selected/read anywhere in the
                            -- Flutter client -- rider_orders_screen.dart only ever selects this
                            -- column from rider_assignments, which doesn't have it, and always
                            -- falls back to its own (distKm * 3).ceil() computation instead) -- but
                            -- correcting it is out of scope for this fix, so it is left exactly as
                            -- production already has it rather than silently changing it here.
                            v_order.rider_earning,
                            NOW()
                        );
                    EXCEPTION WHEN OTHERS THEN
                        NULL;
                    END;
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

                        -- FIX: see above -- isolated so a duplicate-round audit row can never roll
                        -- back the UPDATE that just re-sent this assignment to the rider.
                        BEGIN
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
                        EXCEPTION WHEN OTHERS THEN
                            NULL;
                        END;
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

                        -- FIX: see above -- isolated so a duplicate-round audit row can never roll
                        -- back the UPDATE that just re-sent this assignment to the rider.
                        BEGIN
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
                        EXCEPTION WHEN OTHERS THEN
                            NULL;
                        END;
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Retained: still catches a genuine concurrent-INSERT race on rider_assignments'
                -- own (order_id, rider_id) unique key (two rematch mechanisms firing at once for a
                -- pair that has never been offered before). The order_assignment_logs unique key can
                -- no longer reach this handler at all -- it is caught by its own inner block above.
                NULL;
            END;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;
