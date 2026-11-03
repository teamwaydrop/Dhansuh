-- REVIEW / REHEARSAL ONLY. HOLD. Ends ROLLBACK. Not an automatic migration.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
DO $guard$ BEGIN IF md5(pg_get_functiondef('public.assign_nearby_searching_orders_core(uuid,uuid,double precision,double precision,partner_service_mode_enum)'::regprocedure)) IS DISTINCT FROM '444701b2f06a4dc8f49be3ddd9cd564b' THEN RAISE EXCEPTION 'Definition drift'; END IF; END $guard$;
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode partner_service_mode_enum)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    v_lat_delta double precision;
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

    v_lat_delta := degrees(v_radius_km / 6371.0) + 1e-5;

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
          AND CASE WHEN p_current_lat BETWEEN -90 AND 90
                        AND o.pickup_lat BETWEEN -90 AND 90
                        AND v_radius_km >= 0 AND v_radius_km < pi() * 6371.0
                   THEN o.pickup_lat BETWEEN p_current_lat - v_lat_delta AND p_current_lat + v_lat_delta
                   ELSE true END
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
$function$
;
ROLLBACK;
