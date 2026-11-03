-- SYNTHETIC DATA ONLY. Fixed loopback test database; never run remotely.
DO $$ BEGIN IF current_database()<>'waydrop_blocker_test' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Fixed local synthetic database required'; END IF; END $$;
--
-- PostgreSQL database dump
--

\restrict QwAYy535bokW5L11CzdfbkRv1sODpmt6HFgxXROgGG37ezH48UsThLvwgSbMKUN

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA auth;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: activation_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.activation_status_enum AS ENUM (
    'inactive',
    'profile_pending',
    'active',
    'suspended'
);


--
-- Name: assignment_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.assignment_status_enum AS ENUM (
    'sent',
    'viewed',
    'accepted',
    'rejected',
    'timed_out',
    'expired',
    'cancelled'
);


--
-- Name: cancelled_by_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cancelled_by_enum AS ENUM (
    'user',
    'rider',
    'admin',
    'system'
);


--
-- Name: cashfree_beneficiary_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cashfree_beneficiary_status_enum AS ENUM (
    'pending',
    'active',
    'failed',
    'disabled'
);


--
-- Name: dispute_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.dispute_status_enum AS ENUM (
    'open',
    'investigating',
    'resolved_paid',
    'resolved_unpaid'
);


--
-- Name: fare_payment_method_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.fare_payment_method_enum AS ENUM (
    'personal_upi',
    'cashfree',
    'cash'
);


--
-- Name: intercity_assignment_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.intercity_assignment_status_enum AS ENUM (
    'sent',
    'viewed',
    'accepted',
    'rejected',
    'timed_out',
    'expired',
    'cancelled',
    'accepted_by_user'
);


--
-- Name: kyc_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.kyc_status_enum AS ENUM (
    'pending',
    'under_review',
    'approved',
    'rejected',
    'resubmitted'
);


--
-- Name: order_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.order_status_enum AS ENUM (
    'created',
    'searching',
    'accepted',
    'rider_arrived',
    'picked_up',
    'ongoing',
    'rider_at_drop',
    'completed',
    'delivered',
    'cancelled',
    'expired',
    'payment_pending'
);


--
-- Name: order_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.order_type_enum AS ENUM (
    'ride',
    'intercity_ride',
    'ride_sharing',
    'local_parcel',
    'intercity_parcel',
    'batch_delivery',
    'food_delivery',
    'grocery_delivery'
);


--
-- Name: parcel_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.parcel_type_enum AS ENUM (
    'documents',
    'electronics',
    'food',
    'clothes',
    'fragile',
    'others'
);


--
-- Name: partner_service_mode_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.partner_service_mode_enum AS ENUM (
    'local',
    'intercity'
);


--
-- Name: payment_for_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_for_enum AS ENUM (
    'ride_order',
    'parcel_order',
    'wallet_topup',
    'subscription',
    'withdrawal',
    'refund',
    'cod_settlement',
    'ride_boost',
    'intercity_ride_boost',
    'intercity_parcel_boost',
    'intercity_ride_order',
    'intercity_parcel_order',
    'ride_sharing',
    'tax_due'
);


--
-- Name: payment_method_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_method_enum AS ENUM (
    'upi',
    'card',
    'wallet',
    'netbanking',
    'cash',
    'cod',
    'cashfree'
);


--
-- Name: payment_mode_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_mode_enum AS ENUM (
    'cash',
    'online',
    'wallet',
    'upi'
);


--
-- Name: payment_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_status_enum AS ENUM (
    'pending',
    'paid',
    'failed',
    'refunded',
    'partial_refund',
    'cash_collected',
    'cash_pending_settlement'
);


--
-- Name: payout_method_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payout_method_enum AS ENUM (
    'bank_account',
    'upi'
);


--
-- Name: preferred_mode_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.preferred_mode_enum AS ENUM (
    'user',
    'rider'
);


--
-- Name: pricing_city_tier_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pricing_city_tier_enum AS ENUM (
    'tier_1',
    'tier_2'
);


--
-- Name: pricing_service_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pricing_service_type_enum AS ENUM (
    'ride',
    'local_parcel',
    'intercity_parcel',
    'intercity_ride',
    'ride_sharing'
);


--
-- Name: review_tag; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.review_tag AS ENUM (
    'clean_vehicle',
    'polite_behavior',
    'safe_driving',
    'on_time',
    'dirty_vehicle',
    'rude_behavior',
    'unsafe_driving',
    'late_arrival',
    'other',
    'good_behaviour',
    'respectful',
    'easy_to_communicate',
    'clear_instructions',
    'cooperative',
    'ready_at_pickup',
    'late_at_pickup',
    'rude_behaviour',
    'poor_communication',
    'uncooperative',
    'changed_plans',
    'no_show'
);


--
-- Name: rider_account_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.rider_account_status_enum AS ENUM (
    'online',
    'offline',
    'busy',
    'blocked'
);


--
-- Name: rider_withdrawal_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.rider_withdrawal_status_enum AS ENUM (
    'pending',
    'processing',
    'success',
    'failed'
);


--
-- Name: subscription_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.subscription_status_enum AS ENUM (
    'active',
    'expired',
    'cancelled',
    'pending'
);


--
-- Name: travel_plan_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.travel_plan_status_enum AS ENUM (
    'active',
    'completed',
    'cancelled',
    'fully_booked',
    'expired'
);


--
-- Name: vehicle_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.vehicle_type_enum AS ENUM (
    'bike',
    'auto',
    'cab'
);


--
-- Name: weight_category_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.weight_category_enum AS ENUM (
    '0_5',
    '6_15',
    '16_25',
    '26_50'
);


--
-- Name: email(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.email() RETURNS text
    LANGUAGE sql STABLE
    AS $$ SELECT nullif(current_setting('request.jwt.claim.email',true),'') $$;


--
-- Name: role(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.role() RETURNS text
    LANGUAGE sql STABLE
    AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$;


--
-- Name: uid(); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;


--
-- Name: assign_nearby_searching_orders_core(uuid, uuid, double precision, double precision, public.partner_service_mode_enum); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode public.partner_service_mode_enum) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: assign_nearby_searching_orders_to_rider(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_nearby_searching_orders_to_rider() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: calculate_fare_breakdown(numeric, numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_fare_breakdown(p_new_total_fare numeric, p_actual_fare numeric, p_gst_percentage numeric, p_commission_percentage numeric, p_promo_discount numeric DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
DECLARE
    v_new_total_fare numeric;
    v_base_fare numeric;
    v_gst_amount numeric;
    v_boost_amount numeric;
    v_boost_percentage numeric;
    v_boost_rider_earning numeric;
    v_boost_company_earning numeric;
    v_commission_amount numeric;
    v_rider_earning numeric;
    v_final_fare numeric;
BEGIN
    -- WHOLE-RUPEE ROUNDING (20260901000018, unchanged): single point for every post-booking fare
    -- change: boost, intercity negotiation acceptance, plain accept-order re-derivation, and the
    -- fresh commission/GST/rider_earning recompute complete_order_and_settle() and
    -- complete_intercity_parcel_delivery() both run at ride completion.
    v_new_total_fare := ROUND(COALESCE(p_new_total_fare, 0), 0);

    -- Commission base: UNCHANGED -- still the real GST-inclusive decomposition at the order's
    -- actual configured gst_percentage, so the commission RESULT below is identical to before
    -- this migration. This is intentionally NOT set to 0 -- only the amount CHARGED as Platform
    -- GST (v_gst_amount, below) and rider_earning's source are affected.
    v_base_fare := ROUND(v_new_total_fare / (1 + (COALESCE(p_gst_percentage, 5.0) / 100.0)), 2);

    -- PLATFORM GST TEMPORARILY DISABLED (business decision, pending CA/GST confirmation -- see
    -- migration header). Effective amount is 0 -- the column/formula capability is fully
    -- preserved; only the value returned here changes. Re-enable by restoring:
    --   v_gst_amount := ROUND(v_new_total_fare - v_base_fare, 2);
    v_gst_amount := 0;

    -- Signed delta vs. the order's original base fare -- unchanged, still uses v_base_fare (the
    -- commission base), independent of the Platform GST toggle above.
    v_boost_amount := ROUND(v_base_fare - COALESCE(p_actual_fare, 0), 2);
    v_boost_percentage := CASE
        WHEN COALESCE(p_actual_fare, 0) > 0 THEN ROUND((v_boost_amount / p_actual_fare) * 100, 2)
        ELSE 0
    END;
    v_boost_rider_earning := ROUND(v_boost_amount * 0.80, 2);
    v_boost_company_earning := ROUND(v_boost_amount * 0.20, 2);

    -- Commission: UNCHANGED formula and base -- same result as before this migration.
    v_commission_amount := ROUND(v_base_fare * (COALESCE(p_commission_percentage, 0) / 100.0), 2);

    -- RIDER EARNING: was `v_base_fare - v_commission_amount` (which silently excluded the Platform
    -- GST portion from the rider). Now `v_new_total_fare - v_commission_amount` -- with Platform
    -- GST charged at 0, nothing is withheld from the rider for it; the full fare minus commission
    -- only (Government Tax is handled separately, unchanged, in complete_order_and_settle()).
    -- Re-enable Platform GST by restoring: v_rider_earning := ROUND(v_base_fare - v_commission_amount, 2);
    v_rider_earning := ROUND(v_new_total_fare - v_commission_amount, 2);

    -- Whole-rupee here too: a promo-discounted final_fare is still the customer's actual payable
    -- amount and must never carry paise either. Unchanged.
    v_final_fare := GREATEST(0, ROUND(v_new_total_fare - COALESCE(p_promo_discount, 0), 0));

    RETURN jsonb_build_object(
        'current_fare', v_new_total_fare,
        'final_fare', v_final_fare,
        'gst_amount', v_gst_amount,
        'boost_amount', v_boost_amount,
        'boost_percentage', v_boost_percentage,
        'boost_rider_earning', v_boost_rider_earning,
        'boost_company_earning', v_boost_company_earning,
        'commission_amount', v_commission_amount,
        'rider_earning', v_rider_earning
    );
END;
$$;


--
-- Name: can_read_rider_location(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_read_rider_location(p_rider_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT
        -- (A) the rider themselves
        EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = p_rider_id
              AND r.user_id = (SELECT auth.uid())
        )
        OR
        -- (B) a passenger with an ACTIVE order assigned to this rider
        EXISTS (
            SELECT 1 FROM public.orders o
            WHERE o.rider_id = p_rider_id
              AND o.user_id  = (SELECT auth.uid())
              AND o.order_status IN (
                    'accepted', 'rider_arrived', 'picked_up',
                    'rider_at_drop', 'ongoing', 'payment_pending'
                  )
        );
$$;


--
-- Name: check_is_order_candidate_rider(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_is_order_candidate_rider(p_order_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.rider_assignments ra
        INNER JOIN public.riders r ON r.id = ra.rider_id
        WHERE ra.order_id = p_order_id AND r.user_id = p_user_id
    );
$$;


--
-- Name: check_is_order_passenger(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_is_order_passenger(p_order_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id AND user_id = p_user_id
    );
$$;


--
-- Name: check_is_order_passenger_for_intercity(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_is_order_passenger_for_intercity(p_order_id uuid, p_user_id uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id
          AND user_id = p_user_id
          AND order_type IN ('intercity_ride', 'intercity_parcel')
    );
$$;


--
-- Name: check_rider_near_destination_from_rider_locations(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_rider_near_destination_from_rider_locations() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_order RECORD;
    v_dist_km double precision;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, destination_lat, destination_lng
    INTO v_order
    FROM public.orders
    WHERE rider_id = NEW.rider_id
      AND order_status = 'ongoing'
      AND near_destination_notified = false
      AND order_type::text LIKE 'intercity%'
      AND destination_lat IS NOT NULL
      AND destination_lng IS NOT NULL
    LIMIT 1;

    IF v_order.id IS NULL THEN
        RETURN NEW;
    END IF;

    v_dist_km := 6371 * acos(
        LEAST(GREATEST(
            cos(radians(v_order.destination_lat))
            * cos(radians(NEW.current_lat))
            * cos(radians(NEW.current_lng) - radians(v_order.destination_lng))
            + sin(radians(v_order.destination_lat))
            * sin(radians(NEW.current_lat))
        , -1.0), 1.0)
    );

    IF v_dist_km <= 3.0 THEN
        UPDATE public.orders
        SET near_destination_notified = true
        WHERE id = v_order.id;

        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Almost There',
            'You are about 10 minutes away from your destination.',
            jsonb_build_object('type', 'trip_near_destination', 'order_id', v_order.id)
        );
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: edge_test_commit_fault(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edge_test_commit_fault() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN IF NEW.order_status='accepted' AND NEW.order_code='EDGE-COMMIT-FAULT' THEN RAISE EXCEPTION 'Injected commit failure'; END IF; RETURN NEW; END $$;


--
-- Name: edge_test_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edge_test_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ BEGIN IF NEW.order_status='accepted' AND OLD.order_status IS DISTINCT FROM NEW.order_status THEN INSERT INTO local_push_capture(user_id,title,body,data) VALUES(NEW.user_id,'accept','synthetic',jsonb_build_object('order_id',NEW.id)); END IF; RETURN NEW; END $$;


--
-- Name: edge_test_fault(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.edge_test_fault() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ BEGIN IF NEW.assignment_status='accepted' AND EXISTS(SELECT 1 FROM orders WHERE id=NEW.order_id AND order_code='EDGE-FAULT') THEN RAISE EXCEPTION 'Injected assignment failure'; END IF; RETURN NEW; END $$;


--
-- Name: enforce_order_rider_service_mode(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_order_rider_service_mode() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_required_mode public.partner_service_mode_enum;
    v_rider_mode public.partner_service_mode_enum;
BEGIN
    -- Only check when rider_id is being set/changed to a non-null value.
    IF NEW.rider_id IS NULL OR NEW.rider_id IS NOT DISTINCT FROM OLD.rider_id THEN
        RETURN NEW;
    END IF;

    SELECT r.service_mode INTO v_rider_mode
    FROM public.riders r
    WHERE r.id = NEW.rider_id;

    v_required_mode := public.get_required_service_mode(NEW.order_type::text, NEW.distance_meters);

    IF v_rider_mode IS NULL THEN
        RAISE EXCEPTION 'Rider % has not selected a Service Mode yet and cannot be assigned order %', NEW.rider_id, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rider_mode != v_required_mode THEN
        RAISE EXCEPTION 'Rider % service_mode (%) does not match the service mode required (%) for order %', NEW.rider_id, v_rider_mode, v_required_mode, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: enforce_rider_assignment_service_mode(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_rider_assignment_service_mode() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_order_type text;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
    v_rider_mode public.partner_service_mode_enum;
BEGIN
    SELECT o.order_type::text, o.distance_meters
    INTO v_order_type, v_distance_meters
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    SELECT r.service_mode INTO v_rider_mode
    FROM public.riders r
    WHERE r.id = NEW.rider_id;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    IF v_rider_mode IS NULL THEN
        RAISE EXCEPTION 'Rider % has not selected a Service Mode yet and cannot be assigned any orders', NEW.rider_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rider_mode != v_required_mode THEN
        RAISE EXCEPTION 'Rider % service_mode (%) does not match the service mode required (%) for order %', NEW.rider_id, v_rider_mode, v_required_mode, NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: find_nearby_riders(uuid, double precision, double precision, double precision, integer, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer, p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[]) RETURNS TABLE(rider_id uuid, user_id uuid, full_name text, vehicle_type text, vehicle_number text, current_lat double precision, current_lng double precision, distance_km numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

    IF auth.uid() IS NOT NULL AND (v_creator_user_id IS NULL OR auth.uid() != v_creator_user_id) THEN
        RETURN;
    END IF;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

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
$$;


--
-- Name: get_active_tax_due_threshold(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_active_tax_due_threshold() RETURNS numeric
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
    SELECT COALESCE(
        (SELECT threshold_amount FROM public.government_tax_config WHERE is_active = true ORDER BY updated_at DESC LIMIT 1),
        100.0
    );
$$;


--
-- Name: get_required_service_mode(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_required_service_mode(p_order_type text, p_distance_meters integer) RETURNS public.partner_service_mode_enum
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
    SELECT CASE
        WHEN p_order_type IN ('intercity_ride', 'intercity_parcel') THEN 'intercity'::public.partner_service_mode_enum
        WHEN p_order_type = 'ride' AND COALESCE(p_distance_meters, 0) > 20000 THEN 'intercity'::public.partner_service_mode_enum
        ELSE 'local'::public.partner_service_mode_enum
    END;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins
    WHERE email = auth.email() AND is_active = true
  );
$$;


--
-- Name: is_rider_blocked_by_cod_limit(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_rider_blocked_by_cod_limit(p_rider_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT COALESCE(
        (SELECT cod_pending_amount FROM public.riders WHERE id = p_rider_id),
        0
    ) >= COALESCE(
        (SELECT cod_limit FROM public.riders WHERE id = p_rider_id),
        500
    );
$$;


--
-- Name: is_rider_blocked_by_tax_due(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_rider_blocked_by_tax_due(p_rider_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
    SELECT COALESCE(
        (SELECT government_tax_due_balance FROM public.riders WHERE id = p_rider_id),
        0
    ) >= public.get_active_tax_due_threshold();
$$;


--
-- Name: on_rider_assignment_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.on_rider_assignment_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_order_type text := NULL;
    v_notification_type text := 'order_assignment';
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            SELECT order_type::text INTO v_order_type FROM public.orders WHERE id = NEW.order_id;

            IF v_order_type IN ('intercity_ride', 'intercity_parcel') THEN
                v_notification_type := 'intercity_order_assignment';
            END IF;

            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', v_notification_type,
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: prevent_local_ride_assignment_to_busy_rider(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_local_ride_assignment_to_busy_rider() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: prevent_service_mode_switch_during_active_order(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_service_mode_switch_during_active_order() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    IF public.rider_is_on_active_trip(NEW.id) THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while a trip is active. Complete or cancel your current trip first.'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: protect_order_financial_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_order_financial_columns() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
           OR NEW.payment_status IS DISTINCT FROM OLD.payment_status
           OR NEW.fare_payment_method IS DISTINCT FROM OLD.fare_payment_method
           OR NEW.current_fare IS DISTINCT FROM OLD.current_fare
           OR NEW.final_fare IS DISTINCT FROM OLD.final_fare
           OR NEW.boost_amount IS DISTINCT FROM OLD.boost_amount
           OR NEW.boost_percentage IS DISTINCT FROM OLD.boost_percentage
           -- Added by this migration: the 2% PG-charge breakdown field is server-written only.
           OR NEW.pg_charge_amount IS DISTINCT FROM OLD.pg_charge_amount
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: protect_order_state_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_order_state_columns() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_order_state_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.order_status IS DISTINCT FROM OLD.order_status
           OR NEW.pickup_otp IS DISTINCT FROM OLD.pickup_otp
           OR NEW.delivery_otp IS DISTINCT FROM OLD.delivery_otp
           OR NEW.rider_id IS DISTINCT FROM OLD.rider_id
        THEN
            RAISE EXCEPTION 'Direct modification of order status/OTP/assignment columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: protect_rider_financial_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_rider_financial_columns() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_rider_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.wallet_balance IS DISTINCT FROM OLD.wallet_balance
           OR NEW.cod_pending_amount IS DISTINCT FROM OLD.cod_pending_amount
           OR NEW.cod_limit IS DISTINCT FROM OLD.cod_limit
           OR NEW.subscription_active IS DISTINCT FROM OLD.subscription_active
           OR NEW.subscription_expires_at IS DISTINCT FROM OLD.subscription_expires_at
           OR NEW.commission_waiver_active IS DISTINCT FROM OLD.commission_waiver_active
           OR NEW.government_tax_due_balance IS DISTINCT FROM OLD.government_tax_due_balance
           OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
           OR NEW.free_trial_started_at IS DISTINCT FROM OLD.free_trial_started_at
           OR NEW.free_trial_expires_at IS DISTINCT FROM OLD.free_trial_expires_at
           OR NEW.free_trial_used IS DISTINCT FROM OLD.free_trial_used
        THEN
            RAISE EXCEPTION 'Direct modification of rider financial/subscription columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: rider_is_on_active_trip(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rider_is_on_active_trip(p_rider_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.rider_id = p_rider_id
          AND (
                o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')
                OR (
                    o.order_status::text = 'accepted'
                    AND (
                        public.get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'
                        OR o.trip_started_at IS NOT NULL
                    )
                )
              )
    );
$$;


--
-- Name: send_push_notification_fnc(uuid, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_push_notification_fnc(uuid, text, text, jsonb) RETURNS void
    LANGUAGE sql
    AS $_$ INSERT INTO local_push_capture(user_id,title,body,data) VALUES($1,$2,$3,$4) $_$;


--
-- Name: sync_riders_gps_to_rider_locations(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_riders_gps_to_rider_locations() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    INSERT INTO public.rider_locations AS rl
        (rider_id, current_lat, current_lng, current_heading,
         last_location_updated_at, last_active_at, updated_at)
    VALUES
        (NEW.id, NEW.current_lat, NEW.current_lng, NEW.current_heading,
         NEW.last_location_updated_at, NEW.last_active_at, now())
    ON CONFLICT (rider_id) DO UPDATE SET
        current_lat              = EXCLUDED.current_lat,
        current_lng              = EXCLUDED.current_lng,
        current_heading          = EXCLUDED.current_heading,
        last_location_updated_at = EXCLUDED.last_location_updated_at,
        last_active_at           = EXCLUDED.last_active_at,
        updated_at               = now();

    RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admins (
    id uuid NOT NULL,
    email text,
    is_active boolean
);


--
-- Name: dispatch_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dispatch_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    config_code text NOT NULL,
    round_1_radius_km numeric DEFAULT 3 NOT NULL,
    round_1_batch_size integer DEFAULT 3 NOT NULL,
    round_2_radius_km numeric DEFAULT 6 NOT NULL,
    round_2_batch_size integer DEFAULT 5 NOT NULL,
    round_3_radius_km numeric DEFAULT 10 NOT NULL,
    round_3_batch_size integer DEFAULT 8 NOT NULL,
    rider_response_timeout_sec integer DEFAULT 25 NOT NULL,
    max_search_duration_sec integer DEFAULT 900 NOT NULL,
    reject_cooldown_sec integer DEFAULT 600 NOT NULL,
    timeout_cooldown_sec integer DEFAULT 120 NOT NULL,
    rider_location_stale_sec integer DEFAULT 30 NOT NULL,
    max_active_orders_per_rider integer DEFAULT 1 NOT NULL,
    allow_round_3 boolean DEFAULT true,
    allow_boosted_priority boolean DEFAULT true,
    is_active boolean DEFAULT true,
    updated_by_admin_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    round_2_trigger_if_no_riders_sec integer DEFAULT 60,
    round_2_trigger_after_sec integer DEFAULT 300,
    round_3_trigger_after_sec integer DEFAULT 600
);


--
-- Name: government_tax_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.government_tax_config (
    threshold_amount numeric,
    is_active boolean,
    updated_at timestamp with time zone
);


--
-- Name: intercity_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.intercity_requests (
    parcel_id uuid,
    traveller_id uuid,
    status text
);


--
-- Name: local_push_capture; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_push_capture (
    id bigint NOT NULL,
    user_id uuid,
    title text,
    body text,
    data jsonb
);


--
-- Name: local_push_capture_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.local_push_capture_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: local_push_capture_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.local_push_capture_id_seq OWNED BY public.local_push_capture.id;


--
-- Name: order_assignment_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_assignment_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    rider_id uuid NOT NULL,
    assignment_status public.intercity_assignment_status_enum DEFAULT 'sent'::public.intercity_assignment_status_enum NOT NULL,
    assignment_round integer DEFAULT 1,
    rider_distance_km numeric,
    estimated_pickup_time_min integer,
    sent_at timestamp with time zone DEFAULT now(),
    viewed_at timestamp with time zone,
    responded_at timestamp with time zone,
    rejection_reason text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_code text NOT NULL,
    user_id uuid NOT NULL,
    rider_id uuid,
    order_type public.order_type_enum NOT NULL,
    vehicle_type public.vehicle_type_enum,
    order_status public.order_status_enum DEFAULT 'created'::public.order_status_enum NOT NULL,
    pricing_config_id uuid,
    distance_meters integer NOT NULL,
    distance_km numeric NOT NULL,
    estimated_duration_min integer,
    actual_duration_min integer,
    time_taken_seconds integer,
    pickup_address text NOT NULL,
    pickup_lat double precision NOT NULL,
    pickup_lng double precision NOT NULL,
    destination_address text NOT NULL,
    destination_lat double precision NOT NULL,
    destination_lng double precision NOT NULL,
    actual_fare numeric NOT NULL,
    current_fare numeric NOT NULL,
    final_fare numeric,
    base_fare numeric DEFAULT 0,
    distance_fare numeric DEFAULT 0,
    time_fare numeric DEFAULT 0,
    waiting_charge numeric DEFAULT 0,
    platform_fee numeric DEFAULT 0,
    gst_percentage numeric DEFAULT 0,
    gst_amount numeric DEFAULT 0,
    commission_percentage numeric DEFAULT 0,
    commission_amount numeric DEFAULT 0,
    rider_earning numeric DEFAULT 0,
    boost_amount numeric DEFAULT 0,
    subscription_commission_waived boolean DEFAULT false,
    pricing_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    payment_mode public.payment_mode_enum NOT NULL,
    payment_status public.payment_status_enum DEFAULT 'pending'::public.payment_status_enum NOT NULL,
    payment_id uuid,
    pickup_otp text,
    delivery_otp text,
    search_expires_at timestamp with time zone,
    cancelled_by public.cancelled_by_enum,
    cancel_reason text,
    parcel_type public.parcel_type_enum,
    receiver_name text,
    receiver_phone text,
    weight_category text,
    actual_weight_kg numeric,
    parcel_images text[],
    special_instructions text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    accepted_at timestamp with time zone,
    rider_arrived_at timestamp with time zone,
    picked_up_at timestamp with time zone,
    rider_at_drop_at timestamp with time zone,
    completed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    pickup_otp_attempts integer DEFAULT 0,
    delivery_otp_attempts integer DEFAULT 0,
    boost_company_earning numeric DEFAULT 0,
    boost_rider_earning numeric DEFAULT 0,
    boost_percentage numeric DEFAULT 0,
    dispatch_attempts integer DEFAULT 0,
    boost_round integer DEFAULT 0,
    current_search_radius_km numeric DEFAULT 3,
    last_dispatched_at timestamp with time zone,
    rider_rejections_count integer DEFAULT 0,
    redispatch_count integer DEFAULT 0,
    pickup_city text,
    destination_city text,
    travel_date timestamp with time zone,
    dispatch_state jsonb DEFAULT '{}'::jsonb,
    created_ip_address inet,
    created_lat double precision,
    created_lng double precision,
    sender_declaration_accepted boolean DEFAULT false,
    sender_declaration_accepted_at timestamp with time zone,
    pickup_verification_completed boolean DEFAULT false,
    pickup_verification_completed_at timestamp with time zone,
    compliance_flagged boolean DEFAULT false,
    compliance_notes text,
    created_device_ref text,
    created_device_record_id uuid,
    created_device_model text,
    created_device_brand text,
    created_os_version text,
    created_app_version text,
    compliance_status text DEFAULT 'pending'::text,
    compliance_score integer DEFAULT 100,
    compliance_retention_until timestamp with time zone,
    parcel_declared_value numeric,
    high_risk_parcel boolean DEFAULT false,
    dispatch_worker_running boolean DEFAULT false,
    dispatch_worker_started_at timestamp with time zone,
    seats_requested integer DEFAULT 1 NOT NULL,
    near_destination_notified boolean DEFAULT false NOT NULL,
    trip_started_at timestamp with time zone,
    upi_payment_prompted_at timestamp with time zone,
    fare_payment_method public.fare_payment_method_enum,
    fare_payment_attempted_at timestamp with time zone,
    fare_paid_at timestamp with time zone,
    fare_payment_reference text,
    fare_payment_screenshot_url text,
    idempotency_key text,
    pg_charge_amount numeric DEFAULT 0 NOT NULL,
    CONSTRAINT check_intercity_parcel_weight CHECK (((order_type <> 'intercity_parcel'::public.order_type_enum) OR ((actual_weight_kg IS NOT NULL) AND (actual_weight_kg > (0)::numeric)))),
    CONSTRAINT chk_actual_fare CHECK ((actual_fare >= (0)::numeric)),
    CONSTRAINT chk_commission_percentage CHECK (((commission_percentage >= (0)::numeric) AND (commission_percentage <= (100)::numeric))),
    CONSTRAINT chk_current_fare CHECK ((current_fare >= (0)::numeric)),
    CONSTRAINT chk_distance_km CHECK ((distance_km >= (0)::numeric)),
    CONSTRAINT chk_distance_meters CHECK ((distance_meters >= 0)),
    CONSTRAINT chk_final_fare CHECK (((final_fare IS NULL) OR (final_fare >= (0)::numeric))),
    CONSTRAINT chk_gst_percentage CHECK (((gst_percentage >= (0)::numeric) AND (gst_percentage <= (100)::numeric))),
    CONSTRAINT orders_compliance_status_check CHECK ((compliance_status = ANY (ARRAY['pending'::text, 'verified'::text, 'flagged'::text, 'investigating'::text])))
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid NOT NULL
);


--
-- Name: pricing_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pricing_config (
    id uuid NOT NULL
);


--
-- Name: rider_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rider_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    rider_id uuid NOT NULL,
    assignment_round integer DEFAULT 1 NOT NULL,
    assignment_status public.intercity_assignment_status_enum DEFAULT 'sent'::public.intercity_assignment_status_enum NOT NULL,
    distance_km numeric,
    estimated_earnings numeric,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    viewed_at timestamp with time zone,
    responded_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_seen_at timestamp with time zone,
    last_response_at timestamp with time zone,
    response_type text,
    hidden_until timestamp with time zone,
    last_seen_fare numeric,
    accepted_at timestamp with time zone,
    rejected_at timestamp with time zone
);


--
-- Name: rider_kyc; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rider_kyc (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    full_name text NOT NULL,
    father_name text NOT NULL,
    vehicle_type public.vehicle_type_enum NOT NULL,
    aadhaar_number text NOT NULL,
    pan_number text NOT NULL,
    driving_license_number text NOT NULL,
    vehicle_number text NOT NULL,
    rider_image text NOT NULL,
    aadhaar_front_image text NOT NULL,
    aadhaar_back_image text NOT NULL,
    pan_front_image text NOT NULL,
    pan_back_image text NOT NULL,
    license_front_image text NOT NULL,
    license_back_image text NOT NULL,
    vehicle_image text NOT NULL,
    kyc_status public.kyc_status_enum DEFAULT 'pending'::public.kyc_status_enum NOT NULL,
    activation_status public.activation_status_enum DEFAULT 'inactive'::public.activation_status_enum NOT NULL,
    handled_by_admin_id uuid,
    approved_at timestamp with time zone,
    rejected_at timestamp with time zone,
    rejection_reason text,
    activated_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    rejection_count integer DEFAULT 0,
    blocked_until timestamp with time zone,
    date_of_birth date NOT NULL,
    "VECHILE_RC_front_image" text,
    "VECHILE_RC_back_image" text,
    CONSTRAINT aadhaar_length_check CHECK ((length(aadhaar_number) = 12)),
    CONSTRAINT pan_format_check CHECK ((pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'::text)),
    CONSTRAINT rider_minimum_age_check CHECK ((date_of_birth <= (CURRENT_DATE - '18 years'::interval)))
);


--
-- Name: rider_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rider_locations (
    rider_id uuid NOT NULL,
    current_lat double precision,
    current_lng double precision,
    current_heading double precision,
    last_location_updated_at timestamp with time zone,
    last_active_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: riders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.riders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kyc_id uuid NOT NULL,
    user_id uuid NOT NULL,
    rating numeric DEFAULT 5,
    total_orders integer DEFAULT 0,
    total_completed_orders integer DEFAULT 0,
    total_cancelled_orders integer DEFAULT 0,
    total_earnings numeric DEFAULT 0,
    today_earnings numeric DEFAULT 0,
    wallet_balance numeric DEFAULT 0,
    cod_pending_amount numeric DEFAULT 0,
    cod_limit numeric DEFAULT '500'::numeric,
    account_status public.rider_account_status_enum DEFAULT 'offline'::public.rider_account_status_enum NOT NULL,
    current_lat double precision,
    current_lng double precision,
    current_heading double precision,
    last_location_updated_at timestamp with time zone,
    last_active_at timestamp with time zone,
    subscription_active boolean DEFAULT false,
    subscription_expires_at timestamp with time zone,
    commission_waiver_active boolean DEFAULT false,
    is_verified boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    last_dormant_notification_sent_at timestamp with time zone,
    last_sub_offline_notification_sent_at timestamp with time zone,
    service_mode public.partner_service_mode_enum,
    government_tax_due_balance numeric DEFAULT 0 NOT NULL,
    rating_sum numeric DEFAULT 0 NOT NULL,
    total_ratings integer DEFAULT 0 NOT NULL,
    free_trial_started_at timestamp with time zone,
    free_trial_expires_at timestamp with time zone,
    free_trial_used boolean DEFAULT false NOT NULL
);


--
-- Name: user_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_devices (
    id uuid NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL
);


--
-- Name: local_push_capture id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_push_capture ALTER COLUMN id SET DEFAULT nextval('public.local_push_capture_id_seq'::regclass);


--
-- Data for Name: admins; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admins (id, email, is_active) FROM stdin;
\.


--
-- Data for Name: dispatch_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.dispatch_config (id, config_code, round_1_radius_km, round_1_batch_size, round_2_radius_km, round_2_batch_size, round_3_radius_km, round_3_batch_size, rider_response_timeout_sec, max_search_duration_sec, reject_cooldown_sec, timeout_cooldown_sec, rider_location_stale_sec, max_active_orders_per_rider, allow_round_3, allow_boosted_priority, is_active, updated_by_admin_id, created_at, updated_at, round_2_trigger_if_no_riders_sec, round_2_trigger_after_sec, round_3_trigger_after_sec) FROM stdin;
f8ea5c57-4a66-4980-a67f-03dd9a077f7c	TEST	3	3	5	5	10	8	25	900	600	120	60	1	t	t	t	\N	2026-11-02 09:16:30.876219+05:30	2026-11-02 09:16:30.876219+05:30	60	300	600
\.


--
-- Data for Name: government_tax_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.government_tax_config (threshold_amount, is_active, updated_at) FROM stdin;
100	t	2026-11-02 09:16:30.875296+05:30
\.


--
-- Data for Name: intercity_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.intercity_requests (parcel_id, traveller_id, status) FROM stdin;
\.


--
-- Data for Name: local_push_capture; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.local_push_capture (id, user_id, title, body, data) FROM stdin;
9	00000000-0000-4000-8000-000000009000	Almost There	You are about 10 minutes away from your destination.	{"type": "trip_near_destination", "order_id": "00000000-0000-4000-8000-000000002000"}
50	00000000-0000-4000-8000-000000009001	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000004513", "assignment_id": "91d930ac-b61c-4806-98c4-b17226154bdd"}
51	00000000-0000-4000-8000-000000009007	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000004513", "assignment_id": "644ed4d2-d11a-4928-b756-0618eda1faa3"}
52	00000000-0000-4000-8000-000000009000	accept	synthetic	{"order_id": "00000000-0000-4000-8000-000000004513"}
53	00000000-0000-4000-8000-000000009001	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "6a4752cf-2ec1-4988-90b1-ef73563962f3"}
54	00000000-0000-4000-8000-000000009007	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "e61b1d98-c99b-44cf-97d9-9f1bd271435d"}
55	00000000-0000-4000-8000-000000009001	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "014a3f89-c4d1-43e0-8b4f-1c5236ce369b"}
56	00000000-0000-4000-8000-000000009007	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "a8f9e41c-72e5-4f74-876d-693cbb9705ca"}
57	00000000-0000-4000-8000-000000009000	accept	synthetic	{"order_id": "00000000-0000-4000-8000-000000003000"}
58	00000000-0000-4000-8000-000000009001	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "cc5c9229-7faa-4925-b389-03897c9aa73a"}
59	00000000-0000-4000-8000-000000009007	New Order Request	You have a new order request nearby!	{"type": "order_assignment", "order_id": "00000000-0000-4000-8000-000000003000", "assignment_id": "72ca255d-4acc-48be-968e-c39496f350f2"}
60	00000000-0000-4000-8000-000000009000	accept	synthetic	{"order_id": "00000000-0000-4000-8000-000000003000"}
\.


--
-- Data for Name: order_assignment_logs; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.order_assignment_logs (id, order_id, rider_id, assignment_status, assignment_round, rider_distance_km, estimated_pickup_time_min, sent_at, viewed_at, responded_at, rejection_reason, metadata, created_at) FROM stdin;
488703cf-eb2e-4b98-b934-28c61c47fd2e	00000000-0000-4000-8000-000000001002	00000000-0000-4000-8000-000000000203	sent	1	0	80	2026-11-02 09:17:34.980705+05:30	\N	\N	\N	{}	2026-11-02 09:17:34.980705+05:30
027c0a04-0618-416d-a62f-4f767da4dfc9	00000000-0000-4000-8000-000000001000	00000000-0000-4000-8000-000000000201	sent	1	0	80	2026-11-02 09:17:35.006568+05:30	\N	\N	\N	{}	2026-11-02 09:17:35.006568+05:30
ac6cd655-41a2-4912-88b0-9bf5b1341051	00000000-0000-4000-8000-000000001006	00000000-0000-4000-8000-000000000201	sent	1	0	80	2026-11-02 09:17:35.006568+05:30	\N	\N	\N	{}	2026-11-02 09:17:35.006568+05:30
73ac75ee-d75f-41fd-8503-9d38be4234fa	00000000-0000-4000-8000-000000003000	00000000-0000-4000-8000-000000000201	accepted	1	\N	\N	2026-11-02 09:23:07.12028+05:30	\N	2026-11-02 09:23:07.12028+05:30	\N	{}	2026-11-02 09:23:07.12028+05:30
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.orders (id, order_code, user_id, rider_id, order_type, vehicle_type, order_status, pricing_config_id, distance_meters, distance_km, estimated_duration_min, actual_duration_min, time_taken_seconds, pickup_address, pickup_lat, pickup_lng, destination_address, destination_lat, destination_lng, actual_fare, current_fare, final_fare, base_fare, distance_fare, time_fare, waiting_charge, platform_fee, gst_percentage, gst_amount, commission_percentage, commission_amount, rider_earning, boost_amount, subscription_commission_waived, pricing_snapshot, payment_mode, payment_status, payment_id, pickup_otp, delivery_otp, search_expires_at, cancelled_by, cancel_reason, parcel_type, receiver_name, receiver_phone, weight_category, actual_weight_kg, parcel_images, special_instructions, created_at, updated_at, accepted_at, rider_arrived_at, picked_up_at, rider_at_drop_at, completed_at, cancelled_at, pickup_otp_attempts, delivery_otp_attempts, boost_company_earning, boost_rider_earning, boost_percentage, dispatch_attempts, boost_round, current_search_radius_km, last_dispatched_at, rider_rejections_count, redispatch_count, pickup_city, destination_city, travel_date, dispatch_state, created_ip_address, created_lat, created_lng, sender_declaration_accepted, sender_declaration_accepted_at, pickup_verification_completed, pickup_verification_completed_at, compliance_flagged, compliance_notes, created_device_ref, created_device_record_id, created_device_model, created_device_brand, created_os_version, created_app_version, compliance_status, compliance_score, compliance_retention_until, parcel_declared_value, high_risk_parcel, dispatch_worker_running, dispatch_worker_started_at, seats_requested, near_destination_notified, trip_started_at, upi_payment_prompted_at, fare_payment_method, fare_payment_attempted_at, fare_paid_at, fare_payment_reference, fare_payment_screenshot_url, idempotency_key, pg_charge_amount) FROM stdin;
00000000-0000-4000-8000-000000001000	TEST-1000	00000000-0000-4000-8000-000000009000	\N	ride	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1000	17	79	SYNTHETIC-1000	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	5	\N	\N	2026-11-02 09:16:53.04003+05:30	2026-11-02 09:16:53.04003+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001001	TEST-1001	00000000-0000-4000-8000-000000009000	\N	intercity_ride	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1001	17	79	SYNTHETIC-1001	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	12	\N	\N	2026-11-02 09:16:53.223672+05:30	2026-11-02 09:16:53.223672+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001002	TEST-1002	00000000-0000-4000-8000-000000009000	\N	ride_sharing	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1002	17	79	SYNTHETIC-1002	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	5	\N	\N	2026-11-02 09:16:53.376488+05:30	2026-11-02 09:16:53.376488+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001003	TEST-1003	00000000-0000-4000-8000-000000009000	\N	local_parcel	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1003	17	79	SYNTHETIC-1003	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	12	\N	\N	2026-11-02 09:16:53.496492+05:30	2026-11-02 09:16:53.496492+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001004	TEST-1004	00000000-0000-4000-8000-000000009000	\N	intercity_parcel	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1004	17	79	SYNTHETIC-1004	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	5	\N	\N	2026-11-02 09:16:53.628192+05:30	2026-11-02 09:16:53.628192+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001005	TEST-1005	00000000-0000-4000-8000-000000009000	\N	batch_delivery	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1005	17	79	SYNTHETIC-1005	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	12	\N	\N	2026-11-02 09:16:53.879002+05:30	2026-11-02 09:16:53.879002+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001006	TEST-1006	00000000-0000-4000-8000-000000009000	\N	food_delivery	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1006	17	79	SYNTHETIC-1006	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	5	\N	\N	2026-11-02 09:16:54.103836+05:30	2026-11-02 09:16:54.103836+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000001007	TEST-1007	00000000-0000-4000-8000-000000009000	\N	grocery_delivery	bike	searching	\N	1000	1	\N	\N	\N	SYNTHETIC-1007	17	79	SYNTHETIC-1007	17.01	79	100	100	\N	0	0	0	0	0	0	0	0	0	95	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	12	\N	\N	2026-11-02 09:16:54.21698+05:30	2026-11-02 09:16:54.21698+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000002000	TEST-2000	00000000-0000-4000-8000-000000009000	00000000-0000-4000-8000-000000000202	intercity_ride	bike	ongoing	\N	1000	1	\N	\N	\N	SYNTHETIC-2000	17	79	SYNTHETIC-2000	17	79	100	100	\N	0	0	0	0	0	0	0	0	0	80	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	2026-11-02 09:17:36.295751+05:30	2026-11-02 09:17:36.295751+05:30	\N	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	t	\N	\N	\N	\N	\N	\N	\N	\N	0
00000000-0000-4000-8000-000000003000	SYNTHETIC-RACE	00000000-0000-4000-8000-000000009000	00000000-0000-4000-8000-000000000201	ride	bike	accepted	\N	1000	1	\N	\N	\N	SYNTHETIC-1000	17	79	SYNTHETIC-1000	17.01	79	100	100	90	0	0	0	0	0	5	0	10	9.52	90.48	0	f	{}	cash	pending	\N	\N	\N	\N	\N	\N	\N	\N	\N	\N	5	\N	\N	2026-11-02 09:16:53.04003+05:30	2026-11-02 09:23:07.12028+05:30	2026-11-02 09:23:07.12028+05:30	\N	\N	\N	\N	\N	0	0	0	0	0	0	0	3	\N	0	0	\N	\N	\N	{}	\N	\N	\N	f	\N	f	\N	f	\N	\N	\N	\N	\N	\N	\N	pending	100	\N	\N	f	f	\N	1	f	\N	\N	\N	\N	\N	\N	\N	\N	0
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payments (id) FROM stdin;
\.


--
-- Data for Name: pricing_config; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.pricing_config (id) FROM stdin;
\.


--
-- Data for Name: rider_assignments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.rider_assignments (id, order_id, rider_id, assignment_round, assignment_status, distance_km, estimated_earnings, sent_at, viewed_at, responded_at, expires_at, created_at, updated_at, last_seen_at, last_response_at, response_type, hidden_until, last_seen_fare, accepted_at, rejected_at) FROM stdin;
c333969a-84ae-4097-b4f5-d955c6c79f5e	00000000-0000-4000-8000-000000001002	00000000-0000-4000-8000-000000000203	1	expired	0	80	2026-11-02 09:17:34.980705+05:30	\N	\N	2026-11-02 09:17:59.980705+05:30	2026-11-02 09:17:34.980705+05:30	2026-11-02 09:17:34.980705+05:30	2026-11-02 09:17:34.980705+05:30	\N	\N	\N	80	\N	\N
50a2f7ad-44da-4ce1-886e-3f644d506e9c	00000000-0000-4000-8000-000000001000	00000000-0000-4000-8000-000000000201	1	sent	0	80	2026-11-02 09:17:35.900321+05:30	\N	\N	2026-11-02 09:18:00.900321+05:30	2026-11-02 09:17:35.006568+05:30	2026-11-02 09:17:35.900321+05:30	2026-11-02 09:17:35.900321+05:30	\N	\N	\N	95	\N	\N
ee638fcb-77df-42ae-9d41-b511a4ede161	00000000-0000-4000-8000-000000001006	00000000-0000-4000-8000-000000000201	1	sent	0	80	2026-11-02 09:17:35.900321+05:30	\N	\N	2026-11-02 09:18:00.900321+05:30	2026-11-02 09:17:35.006568+05:30	2026-11-02 09:17:35.900321+05:30	2026-11-02 09:17:35.900321+05:30	\N	\N	\N	95	\N	\N
72ca255d-4acc-48be-968e-c39496f350f2	00000000-0000-4000-8000-000000003000	00000000-0000-4000-8000-000000000207	1	expired	\N	80	2026-11-02 09:23:06.690759+05:30	\N	\N	2026-11-02 09:28:06.690759+05:30	2026-11-02 09:23:06.690759+05:30	2026-11-02 09:23:07.12028+05:30	\N	2026-11-02 09:23:07.12028+05:30	ignored	\N	\N	\N	\N
cc5c9229-7faa-4925-b389-03897c9aa73a	00000000-0000-4000-8000-000000003000	00000000-0000-4000-8000-000000000201	1	accepted	\N	80	2026-11-02 09:23:06.690759+05:30	\N	2026-11-02 09:23:07.12028+05:30	2026-11-02 09:28:06.690759+05:30	2026-11-02 09:23:06.690759+05:30	2026-11-02 09:23:07.12028+05:30	\N	2026-11-02 09:23:07.12028+05:30	accepted	\N	\N	\N	\N
\.


--
-- Data for Name: rider_kyc; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.rider_kyc (id, user_id, full_name, father_name, vehicle_type, aadhaar_number, pan_number, driving_license_number, vehicle_number, rider_image, aadhaar_front_image, aadhaar_back_image, pan_front_image, pan_back_image, license_front_image, license_back_image, vehicle_image, kyc_status, activation_status, handled_by_admin_id, approved_at, rejected_at, rejection_reason, activated_at, created_at, updated_at, rejection_count, blocked_until, date_of_birth, "VECHILE_RC_front_image", "VECHILE_RC_back_image") FROM stdin;
00000000-0000-4000-8000-000000000101	00000000-0000-4000-8000-000000009001	Synthetic 1	SYNTHETIC-1	bike	000000000001	ABCDE0001F	SYNTHETIC-1	TEST-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	SYNTHETIC-1	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:30.999041+05:30	2026-11-02 09:16:30.999041+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000102	00000000-0000-4000-8000-000000009002	Synthetic 2	SYNTHETIC-2	auto	000000000002	ABCDE0002F	SYNTHETIC-2	TEST-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	SYNTHETIC-2	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:31.209338+05:30	2026-11-02 09:16:31.209338+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000103	00000000-0000-4000-8000-000000009003	Synthetic 3	SYNTHETIC-3	cab	000000000003	ABCDE0003F	SYNTHETIC-3	TEST-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	SYNTHETIC-3	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:31.520424+05:30	2026-11-02 09:16:31.520424+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000104	00000000-0000-4000-8000-000000009004	Synthetic 4	SYNTHETIC-4	bike	000000000004	ABCDE0004F	SYNTHETIC-4	TEST-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	SYNTHETIC-4	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:31.732771+05:30	2026-11-02 09:16:31.732771+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000105	00000000-0000-4000-8000-000000009005	Synthetic 5	SYNTHETIC-5	auto	000000000005	ABCDE0005F	SYNTHETIC-5	TEST-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	SYNTHETIC-5	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:32.151787+05:30	2026-11-02 09:16:32.151787+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000106	00000000-0000-4000-8000-000000009006	Synthetic 6	SYNTHETIC-6	cab	000000000006	ABCDE0006F	SYNTHETIC-6	TEST-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	SYNTHETIC-6	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:32.551511+05:30	2026-11-02 09:16:32.551511+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000107	00000000-0000-4000-8000-000000009007	Synthetic 7	SYNTHETIC-7	bike	000000000007	ABCDE0007F	SYNTHETIC-7	TEST-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	SYNTHETIC-7	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:33.123679+05:30	2026-11-02 09:16:33.123679+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000108	00000000-0000-4000-8000-000000009008	Synthetic 8	SYNTHETIC-8	auto	000000000008	ABCDE0008F	SYNTHETIC-8	TEST-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	SYNTHETIC-8	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:33.603444+05:30	2026-11-02 09:16:33.603444+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000109	00000000-0000-4000-8000-000000009009	Synthetic 9	SYNTHETIC-9	cab	000000000009	ABCDE0009F	SYNTHETIC-9	TEST-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	SYNTHETIC-9	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:34.094883+05:30	2026-11-02 09:16:34.094883+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000110	00000000-0000-4000-8000-000000009010	Synthetic 10	SYNTHETIC-10	bike	000000000010	ABCDE0010F	SYNTHETIC-10	TEST-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	SYNTHETIC-10	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:34.423249+05:30	2026-11-02 09:16:34.423249+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000111	00000000-0000-4000-8000-000000009011	Synthetic 11	SYNTHETIC-11	auto	000000000011	ABCDE0011F	SYNTHETIC-11	TEST-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	SYNTHETIC-11	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:34.646396+05:30	2026-11-02 09:16:34.646396+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000112	00000000-0000-4000-8000-000000009012	Synthetic 12	SYNTHETIC-12	cab	000000000012	ABCDE0012F	SYNTHETIC-12	TEST-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	SYNTHETIC-12	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:34.956203+05:30	2026-11-02 09:16:34.956203+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000113	00000000-0000-4000-8000-000000009013	Synthetic 13	SYNTHETIC-13	bike	000000000013	ABCDE0013F	SYNTHETIC-13	TEST-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	SYNTHETIC-13	rejected	active	\N	\N	\N	\N	\N	2026-11-02 09:16:35.246559+05:30	2026-11-02 09:16:35.246559+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000114	00000000-0000-4000-8000-000000009014	Synthetic 14	SYNTHETIC-14	auto	000000000014	ABCDE0014F	SYNTHETIC-14	TEST-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	SYNTHETIC-14	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:35.694656+05:30	2026-11-02 09:16:35.694656+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000115	00000000-0000-4000-8000-000000009015	Synthetic 15	SYNTHETIC-15	cab	000000000015	ABCDE0015F	SYNTHETIC-15	TEST-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	SYNTHETIC-15	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:36.080607+05:30	2026-11-02 09:16:36.080607+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000116	00000000-0000-4000-8000-000000009016	Synthetic 16	SYNTHETIC-16	bike	000000000016	ABCDE0016F	SYNTHETIC-16	TEST-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	SYNTHETIC-16	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:36.495345+05:30	2026-11-02 09:16:36.495345+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000117	00000000-0000-4000-8000-000000009017	Synthetic 17	SYNTHETIC-17	auto	000000000017	ABCDE0017F	SYNTHETIC-17	TEST-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	SYNTHETIC-17	approved	inactive	\N	\N	\N	\N	\N	2026-11-02 09:16:36.762894+05:30	2026-11-02 09:16:36.762894+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000118	00000000-0000-4000-8000-000000009018	Synthetic 18	SYNTHETIC-18	cab	000000000018	ABCDE0018F	SYNTHETIC-18	TEST-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	SYNTHETIC-18	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:37.121035+05:30	2026-11-02 09:16:37.121035+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000119	00000000-0000-4000-8000-000000009019	Synthetic 19	SYNTHETIC-19	bike	000000000019	ABCDE0019F	SYNTHETIC-19	TEST-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	SYNTHETIC-19	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:37.476226+05:30	2026-11-02 09:16:37.476226+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000120	00000000-0000-4000-8000-000000009020	Synthetic 20	SYNTHETIC-20	auto	000000000020	ABCDE0020F	SYNTHETIC-20	TEST-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	SYNTHETIC-20	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:37.966103+05:30	2026-11-02 09:16:37.966103+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000121	00000000-0000-4000-8000-000000009021	Synthetic 21	SYNTHETIC-21	cab	000000000021	ABCDE0021F	SYNTHETIC-21	TEST-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	SYNTHETIC-21	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:38.412198+05:30	2026-11-02 09:16:38.412198+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000122	00000000-0000-4000-8000-000000009022	Synthetic 22	SYNTHETIC-22	bike	000000000022	ABCDE0022F	SYNTHETIC-22	TEST-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	SYNTHETIC-22	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:38.827399+05:30	2026-11-02 09:16:38.827399+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000123	00000000-0000-4000-8000-000000009023	Synthetic 23	SYNTHETIC-23	auto	000000000023	ABCDE0023F	SYNTHETIC-23	TEST-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	SYNTHETIC-23	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:39.392639+05:30	2026-11-02 09:16:39.392639+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000124	00000000-0000-4000-8000-000000009024	Synthetic 24	SYNTHETIC-24	cab	000000000024	ABCDE0024F	SYNTHETIC-24	TEST-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	SYNTHETIC-24	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:39.962712+05:30	2026-11-02 09:16:39.962712+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000125	00000000-0000-4000-8000-000000009025	Synthetic 25	SYNTHETIC-25	bike	000000000025	ABCDE0025F	SYNTHETIC-25	TEST-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	SYNTHETIC-25	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:40.434367+05:30	2026-11-02 09:16:40.434367+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000126	00000000-0000-4000-8000-000000009026	Synthetic 26	SYNTHETIC-26	auto	000000000026	ABCDE0026F	SYNTHETIC-26	TEST-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	SYNTHETIC-26	rejected	active	\N	\N	\N	\N	\N	2026-11-02 09:16:40.805017+05:30	2026-11-02 09:16:40.805017+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000127	00000000-0000-4000-8000-000000009027	Synthetic 27	SYNTHETIC-27	cab	000000000027	ABCDE0027F	SYNTHETIC-27	TEST-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	SYNTHETIC-27	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:41.172649+05:30	2026-11-02 09:16:41.172649+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000128	00000000-0000-4000-8000-000000009028	Synthetic 28	SYNTHETIC-28	bike	000000000028	ABCDE0028F	SYNTHETIC-28	TEST-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	SYNTHETIC-28	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:41.51766+05:30	2026-11-02 09:16:41.51766+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000129	00000000-0000-4000-8000-000000009029	Synthetic 29	SYNTHETIC-29	auto	000000000029	ABCDE0029F	SYNTHETIC-29	TEST-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	SYNTHETIC-29	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:41.704961+05:30	2026-11-02 09:16:41.704961+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000130	00000000-0000-4000-8000-000000009030	Synthetic 30	SYNTHETIC-30	cab	000000000030	ABCDE0030F	SYNTHETIC-30	TEST-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	SYNTHETIC-30	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:42.028923+05:30	2026-11-02 09:16:42.028923+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000131	00000000-0000-4000-8000-000000009031	Synthetic 31	SYNTHETIC-31	bike	000000000031	ABCDE0031F	SYNTHETIC-31	TEST-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	SYNTHETIC-31	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:42.216012+05:30	2026-11-02 09:16:42.216012+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000132	00000000-0000-4000-8000-000000009032	Synthetic 32	SYNTHETIC-32	auto	000000000032	ABCDE0032F	SYNTHETIC-32	TEST-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	SYNTHETIC-32	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:42.425325+05:30	2026-11-02 09:16:42.425325+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000133	00000000-0000-4000-8000-000000009033	Synthetic 33	SYNTHETIC-33	cab	000000000033	ABCDE0033F	SYNTHETIC-33	TEST-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	SYNTHETIC-33	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:42.663848+05:30	2026-11-02 09:16:42.663848+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000134	00000000-0000-4000-8000-000000009034	Synthetic 34	SYNTHETIC-34	bike	000000000034	ABCDE0034F	SYNTHETIC-34	TEST-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	SYNTHETIC-34	approved	inactive	\N	\N	\N	\N	\N	2026-11-02 09:16:42.857269+05:30	2026-11-02 09:16:42.857269+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000135	00000000-0000-4000-8000-000000009035	Synthetic 35	SYNTHETIC-35	auto	000000000035	ABCDE0035F	SYNTHETIC-35	TEST-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	SYNTHETIC-35	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:43.070537+05:30	2026-11-02 09:16:43.070537+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000136	00000000-0000-4000-8000-000000009036	Synthetic 36	SYNTHETIC-36	cab	000000000036	ABCDE0036F	SYNTHETIC-36	TEST-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	SYNTHETIC-36	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:43.331824+05:30	2026-11-02 09:16:43.331824+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000137	00000000-0000-4000-8000-000000009037	Synthetic 37	SYNTHETIC-37	bike	000000000037	ABCDE0037F	SYNTHETIC-37	TEST-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	SYNTHETIC-37	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:43.58483+05:30	2026-11-02 09:16:43.58483+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000138	00000000-0000-4000-8000-000000009038	Synthetic 38	SYNTHETIC-38	auto	000000000038	ABCDE0038F	SYNTHETIC-38	TEST-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	SYNTHETIC-38	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:43.824132+05:30	2026-11-02 09:16:43.824132+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000139	00000000-0000-4000-8000-000000009039	Synthetic 39	SYNTHETIC-39	cab	000000000039	ABCDE0039F	SYNTHETIC-39	TEST-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	SYNTHETIC-39	rejected	active	\N	\N	\N	\N	\N	2026-11-02 09:16:44.227093+05:30	2026-11-02 09:16:44.227093+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000140	00000000-0000-4000-8000-000000009040	Synthetic 40	SYNTHETIC-40	bike	000000000040	ABCDE0040F	SYNTHETIC-40	TEST-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	SYNTHETIC-40	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:44.741815+05:30	2026-11-02 09:16:44.741815+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000141	00000000-0000-4000-8000-000000009041	Synthetic 41	SYNTHETIC-41	auto	000000000041	ABCDE0041F	SYNTHETIC-41	TEST-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	SYNTHETIC-41	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:45.370887+05:30	2026-11-02 09:16:45.370887+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000142	00000000-0000-4000-8000-000000009042	Synthetic 42	SYNTHETIC-42	cab	000000000042	ABCDE0042F	SYNTHETIC-42	TEST-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	SYNTHETIC-42	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:45.723943+05:30	2026-11-02 09:16:45.723943+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000143	00000000-0000-4000-8000-000000009043	Synthetic 43	SYNTHETIC-43	bike	000000000043	ABCDE0043F	SYNTHETIC-43	TEST-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	SYNTHETIC-43	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:46.090798+05:30	2026-11-02 09:16:46.090798+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000144	00000000-0000-4000-8000-000000009044	Synthetic 44	SYNTHETIC-44	auto	000000000044	ABCDE0044F	SYNTHETIC-44	TEST-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	SYNTHETIC-44	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:46.375489+05:30	2026-11-02 09:16:46.375489+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000145	00000000-0000-4000-8000-000000009045	Synthetic 45	SYNTHETIC-45	cab	000000000045	ABCDE0045F	SYNTHETIC-45	TEST-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	SYNTHETIC-45	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:46.758351+05:30	2026-11-02 09:16:46.758351+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000146	00000000-0000-4000-8000-000000009046	Synthetic 46	SYNTHETIC-46	bike	000000000046	ABCDE0046F	SYNTHETIC-46	TEST-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	SYNTHETIC-46	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:47.242847+05:30	2026-11-02 09:16:47.242847+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000147	00000000-0000-4000-8000-000000009047	Synthetic 47	SYNTHETIC-47	auto	000000000047	ABCDE0047F	SYNTHETIC-47	TEST-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	SYNTHETIC-47	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:47.655703+05:30	2026-11-02 09:16:47.655703+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000148	00000000-0000-4000-8000-000000009048	Synthetic 48	SYNTHETIC-48	cab	000000000048	ABCDE0048F	SYNTHETIC-48	TEST-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	SYNTHETIC-48	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:47.970112+05:30	2026-11-02 09:16:47.970112+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000149	00000000-0000-4000-8000-000000009049	Synthetic 49	SYNTHETIC-49	bike	000000000049	ABCDE0049F	SYNTHETIC-49	TEST-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	SYNTHETIC-49	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:48.407728+05:30	2026-11-02 09:16:48.407728+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000150	00000000-0000-4000-8000-000000009050	Synthetic 50	SYNTHETIC-50	auto	000000000050	ABCDE0050F	SYNTHETIC-50	TEST-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	SYNTHETIC-50	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:48.76005+05:30	2026-11-02 09:16:48.76005+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000151	00000000-0000-4000-8000-000000009051	Synthetic 51	SYNTHETIC-51	cab	000000000051	ABCDE0051F	SYNTHETIC-51	TEST-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	SYNTHETIC-51	approved	inactive	\N	\N	\N	\N	\N	2026-11-02 09:16:49.169559+05:30	2026-11-02 09:16:49.169559+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000152	00000000-0000-4000-8000-000000009052	Synthetic 52	SYNTHETIC-52	bike	000000000052	ABCDE0052F	SYNTHETIC-52	TEST-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	SYNTHETIC-52	rejected	active	\N	\N	\N	\N	\N	2026-11-02 09:16:49.399779+05:30	2026-11-02 09:16:49.399779+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000153	00000000-0000-4000-8000-000000009053	Synthetic 53	SYNTHETIC-53	auto	000000000053	ABCDE0053F	SYNTHETIC-53	TEST-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	SYNTHETIC-53	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:49.822183+05:30	2026-11-02 09:16:49.822183+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000154	00000000-0000-4000-8000-000000009054	Synthetic 54	SYNTHETIC-54	cab	000000000054	ABCDE0054F	SYNTHETIC-54	TEST-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	SYNTHETIC-54	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:50.167414+05:30	2026-11-02 09:16:50.167414+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000155	00000000-0000-4000-8000-000000009055	Synthetic 55	SYNTHETIC-55	bike	000000000055	ABCDE0055F	SYNTHETIC-55	TEST-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	SYNTHETIC-55	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:50.510092+05:30	2026-11-02 09:16:50.510092+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000156	00000000-0000-4000-8000-000000009056	Synthetic 56	SYNTHETIC-56	auto	000000000056	ABCDE0056F	SYNTHETIC-56	TEST-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	SYNTHETIC-56	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:50.93483+05:30	2026-11-02 09:16:50.93483+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000157	00000000-0000-4000-8000-000000009057	Synthetic 57	SYNTHETIC-57	cab	000000000057	ABCDE0057F	SYNTHETIC-57	TEST-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	SYNTHETIC-57	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:51.296471+05:30	2026-11-02 09:16:51.296471+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000158	00000000-0000-4000-8000-000000009058	Synthetic 58	SYNTHETIC-58	bike	000000000058	ABCDE0058F	SYNTHETIC-58	TEST-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	SYNTHETIC-58	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:51.79963+05:30	2026-11-02 09:16:51.79963+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000159	00000000-0000-4000-8000-000000009059	Synthetic 59	SYNTHETIC-59	auto	000000000059	ABCDE0059F	SYNTHETIC-59	TEST-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	SYNTHETIC-59	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:52.222554+05:30	2026-11-02 09:16:52.222554+05:30	0	\N	1990-01-01	\N	\N
00000000-0000-4000-8000-000000000160	00000000-0000-4000-8000-000000009060	Synthetic 60	SYNTHETIC-60	cab	000000000060	ABCDE0060F	SYNTHETIC-60	TEST-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	SYNTHETIC-60	approved	active	\N	\N	\N	\N	\N	2026-11-02 09:16:52.786532+05:30	2026-11-02 09:16:52.786532+05:30	0	\N	1990-01-01	\N	\N
\.


--
-- Data for Name: rider_locations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.rider_locations (rider_id, current_lat, current_lng, current_heading, last_location_updated_at, last_active_at, created_at, updated_at) FROM stdin;
00000000-0000-4000-8000-000000000202	17	79	124	2026-11-02 09:17:37.324751+05:30	\N	2026-11-02 09:17:36.385098+05:30	2026-11-02 09:17:37.319118+05:30
\.


--
-- Data for Name: riders; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.riders (id, kyc_id, user_id, rating, total_orders, total_completed_orders, total_cancelled_orders, total_earnings, today_earnings, wallet_balance, cod_pending_amount, cod_limit, account_status, current_lat, current_lng, current_heading, last_location_updated_at, last_active_at, subscription_active, subscription_expires_at, commission_waiver_active, is_verified, created_at, updated_at, last_dormant_notification_sent_at, last_sub_offline_notification_sent_at, service_mode, government_tax_due_balance, rating_sum, total_ratings, free_trial_started_at, free_trial_expires_at, free_trial_used) FROM stdin;
00000000-0000-4000-8000-000000000203	00000000-0000-4000-8000-000000000103	00000000-0000-4000-8000-000000009003	5	0	0	0	0	0	0	0	500	online	16.973	79.00039	\N	2026-11-02 09:16:31.533+05:30	\N	f	\N	f	t	2026-11-02 09:16:31.615182+05:30	2026-11-02 09:16:31.615182+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000204	00000000-0000-4000-8000-000000000104	00000000-0000-4000-8000-000000009004	5	0	0	0	0	0	0	0	500	online	16.974	79.00052	\N	2026-11-02 09:16:31.75+05:30	\N	f	\N	f	t	2026-11-02 09:16:31.880963+05:30	2026-11-02 09:16:31.880963+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000205	00000000-0000-4000-8000-000000000105	00000000-0000-4000-8000-000000009005	5	0	0	0	0	0	0	0	500	online	16.975	79.00065	\N	2026-11-02 09:16:32.172+05:30	\N	f	\N	f	t	2026-11-02 09:16:32.375731+05:30	2026-11-02 09:16:32.375731+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000206	00000000-0000-4000-8000-000000000106	00000000-0000-4000-8000-000000009006	5	0	0	0	0	0	0	0	500	online	16.976	79.00078	\N	2026-11-02 09:16:32.572+05:30	\N	f	\N	f	t	2026-11-02 09:16:32.733235+05:30	2026-11-02 09:16:32.733235+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000207	00000000-0000-4000-8000-000000000107	00000000-0000-4000-8000-000000009007	5	0	0	0	0	0	0	0	500	online	16.977	79.00091	\N	2026-11-02 09:16:33.147+05:30	\N	f	\N	f	t	2026-11-02 09:16:33.322492+05:30	2026-11-02 09:16:33.322492+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000208	00000000-0000-4000-8000-000000000108	00000000-0000-4000-8000-000000009008	5	0	0	0	0	0	0	0	500	online	16.978	79.00104	\N	2026-11-02 09:16:33.63+05:30	\N	f	\N	f	t	2026-11-02 09:16:33.947509+05:30	2026-11-02 09:16:33.947509+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000209	00000000-0000-4000-8000-000000000109	00000000-0000-4000-8000-000000009009	5	0	0	0	0	0	0	0	500	online	16.979	79.00117	\N	2026-11-02 09:16:34.119+05:30	\N	f	\N	f	t	2026-11-02 09:16:34.30115+05:30	2026-11-02 09:16:34.30115+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000210	00000000-0000-4000-8000-000000000110	00000000-0000-4000-8000-000000009010	5	0	0	0	0	0	0	0	500	online	16.98	79.0013	\N	2026-11-02 09:16:34.445+05:30	\N	f	\N	f	t	2026-11-02 09:16:34.537125+05:30	2026-11-02 09:16:34.537125+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000211	00000000-0000-4000-8000-000000000111	00000000-0000-4000-8000-000000009011	5	0	0	0	0	0	0	0	500	offline	16.981	79.00143	\N	2026-11-02 09:16:34.661+05:30	\N	f	\N	f	t	2026-11-02 09:16:34.742185+05:30	2026-11-02 09:16:34.742185+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000212	00000000-0000-4000-8000-000000000112	00000000-0000-4000-8000-000000009012	5	0	0	0	0	0	0	0	500	online	16.982	79.00156	\N	2026-11-02 09:16:34.972+05:30	\N	f	\N	f	t	2026-11-02 09:16:35.123161+05:30	2026-11-02 09:16:35.123161+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000213	00000000-0000-4000-8000-000000000113	00000000-0000-4000-8000-000000009013	5	0	0	0	0	0	0	0	500	online	16.983	79.00169	\N	2026-11-02 09:16:35.271+05:30	\N	f	\N	f	t	2026-11-02 09:16:35.492862+05:30	2026-11-02 09:16:35.492862+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000214	00000000-0000-4000-8000-000000000114	00000000-0000-4000-8000-000000009014	5	0	0	0	0	0	0	0	500	online	16.984	79.00182	\N	2026-11-02 09:16:35.717+05:30	\N	f	\N	f	t	2026-11-02 09:16:35.937345+05:30	2026-11-02 09:16:35.937345+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000215	00000000-0000-4000-8000-000000000115	00000000-0000-4000-8000-000000009015	5	0	0	0	0	0	0	0	500	online	16.985	79.00195	\N	2026-11-02 09:16:36.1+05:30	\N	f	\N	f	t	2026-11-02 09:16:36.242772+05:30	2026-11-02 09:16:36.242772+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000216	00000000-0000-4000-8000-000000000116	00000000-0000-4000-8000-000000009016	5	0	0	0	0	0	0	0	500	online	16.986	79.00208	\N	2026-11-02 09:16:36.517+05:30	\N	f	\N	f	t	2026-11-02 09:16:36.633919+05:30	2026-11-02 09:16:36.633919+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000217	00000000-0000-4000-8000-000000000117	00000000-0000-4000-8000-000000009017	5	0	0	0	0	0	0	0	500	online	16.987	79.00221	\N	2026-11-02 09:16:36.776+05:30	\N	f	\N	f	t	2026-11-02 09:16:36.932128+05:30	2026-11-02 09:16:36.932128+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000218	00000000-0000-4000-8000-000000000118	00000000-0000-4000-8000-000000009018	5	0	0	0	0	0	0	0	500	online	16.988	79.00234	\N	2026-11-02 09:16:37.125+05:30	\N	f	\N	f	t	2026-11-02 09:16:37.36044+05:30	2026-11-02 09:16:37.36044+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000219	00000000-0000-4000-8000-000000000119	00000000-0000-4000-8000-000000009019	5	0	0	0	0	0	0	0	500	online	16.989	79.00247	\N	2026-11-02 09:16:37.496+05:30	\N	f	\N	f	t	2026-11-02 09:16:37.770932+05:30	2026-11-02 09:16:37.770932+05:30	\N	\N	local	100	0	0	\N	\N	f
00000000-0000-4000-8000-000000000220	00000000-0000-4000-8000-000000000120	00000000-0000-4000-8000-000000009020	5	0	0	0	0	0	0	0	500	online	16.99	79.0026	\N	2026-11-02 09:16:37.994+05:30	\N	f	\N	f	t	2026-11-02 09:16:38.234497+05:30	2026-11-02 09:16:38.234497+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000221	00000000-0000-4000-8000-000000000121	00000000-0000-4000-8000-000000009021	5	0	0	0	0	0	0	0	500	online	16.991	79.00273	\N	2026-11-02 09:16:38.445+05:30	\N	f	\N	f	t	2026-11-02 09:16:38.620911+05:30	2026-11-02 09:16:38.620911+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000222	00000000-0000-4000-8000-000000000122	00000000-0000-4000-8000-000000009022	5	0	0	0	0	0	0	0	500	offline	16.992	79.00286	\N	2026-11-02 09:16:38.849+05:30	\N	f	\N	f	t	2026-11-02 09:16:39.089005+05:30	2026-11-02 09:16:39.089005+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000223	00000000-0000-4000-8000-000000000123	00000000-0000-4000-8000-000000009023	5	0	0	0	0	0	0	500	500	online	16.993	79.00299	\N	2026-11-02 09:16:39.422+05:30	\N	f	\N	f	t	2026-11-02 09:16:39.634174+05:30	2026-11-02 09:16:39.634174+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000224	00000000-0000-4000-8000-000000000124	00000000-0000-4000-8000-000000009024	5	0	0	0	0	0	0	0	500	online	16.994	79.00312	\N	2026-11-02 09:16:40.007+05:30	\N	f	\N	f	t	2026-11-02 09:16:40.225999+05:30	2026-11-02 09:16:40.225999+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000225	00000000-0000-4000-8000-000000000125	00000000-0000-4000-8000-000000009025	5	0	0	0	0	0	0	0	500	online	16.995	79.00325	\N	2026-11-02 09:16:40.474+05:30	\N	f	\N	f	t	2026-11-02 09:16:40.660083+05:30	2026-11-02 09:16:40.660083+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000226	00000000-0000-4000-8000-000000000126	00000000-0000-4000-8000-000000009026	5	0	0	0	0	0	0	0	500	online	16.996	79.00338	\N	2026-11-02 09:16:40.831+05:30	\N	f	\N	f	t	2026-11-02 09:16:41.012973+05:30	2026-11-02 09:16:41.012973+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000227	00000000-0000-4000-8000-000000000127	00000000-0000-4000-8000-000000009027	5	0	0	0	0	0	0	0	500	online	16.997	79.00351	\N	2026-11-02 09:16:41.189+05:30	\N	f	\N	f	t	2026-11-02 09:16:41.406053+05:30	2026-11-02 09:16:41.406053+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000228	00000000-0000-4000-8000-000000000128	00000000-0000-4000-8000-000000009028	5	0	0	0	0	0	0	0	500	online	16.998	79.00364	\N	2026-11-02 09:16:41.532+05:30	\N	f	\N	f	t	2026-11-02 09:16:41.609113+05:30	2026-11-02 09:16:41.609113+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000229	00000000-0000-4000-8000-000000000129	00000000-0000-4000-8000-000000009029	5	0	0	0	0	0	0	0	500	online	16.999	79.00377	\N	2026-11-02 09:16:41.72+05:30	\N	f	\N	f	t	2026-11-02 09:16:41.809093+05:30	2026-11-02 09:16:41.809093+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000230	00000000-0000-4000-8000-000000000130	00000000-0000-4000-8000-000000009030	5	0	0	0	0	0	0	0	500	online	17	79.0039	\N	2026-11-02 09:16:42.046+05:30	\N	f	\N	f	t	2026-11-02 09:16:42.123802+05:30	2026-11-02 09:16:42.123802+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000231	00000000-0000-4000-8000-000000000131	00000000-0000-4000-8000-000000009031	5	0	0	0	0	0	0	0	500	online	17.001	79.00403	\N	2026-11-02 09:16:42.232+05:30	\N	f	\N	f	t	2026-11-02 09:16:42.320899+05:30	2026-11-02 09:16:42.320899+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000232	00000000-0000-4000-8000-000000000132	00000000-0000-4000-8000-000000009032	5	0	0	0	0	0	0	0	500	online	17.002	79.00416	\N	2026-11-02 09:16:42.437+05:30	\N	f	\N	f	t	2026-11-02 09:16:42.519686+05:30	2026-11-02 09:16:42.519686+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000233	00000000-0000-4000-8000-000000000133	00000000-0000-4000-8000-000000009033	5	0	0	0	0	0	0	0	500	offline	17.003	79.00429	\N	2026-11-02 09:16:42.676+05:30	\N	f	\N	f	t	2026-11-02 09:16:42.755937+05:30	2026-11-02 09:16:42.755937+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000234	00000000-0000-4000-8000-000000000134	00000000-0000-4000-8000-000000009034	5	0	0	0	0	0	0	0	500	online	17.004	79.00442	\N	2026-11-02 09:16:42.874+05:30	\N	f	\N	f	t	2026-11-02 09:16:42.956756+05:30	2026-11-02 09:16:42.956756+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000235	00000000-0000-4000-8000-000000000135	00000000-0000-4000-8000-000000009035	5	0	0	0	0	0	0	0	500	online	17.005	79.00455	\N	2026-11-02 09:16:43.094+05:30	\N	f	\N	f	t	2026-11-02 09:16:43.217136+05:30	2026-11-02 09:16:43.217136+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000236	00000000-0000-4000-8000-000000000136	00000000-0000-4000-8000-000000009036	5	0	0	0	0	0	0	0	500	online	17.006	79.00468	\N	2026-11-02 09:16:43.351+05:30	\N	f	\N	f	t	2026-11-02 09:16:43.453323+05:30	2026-11-02 09:16:43.453323+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000237	00000000-0000-4000-8000-000000000137	00000000-0000-4000-8000-000000009037	5	0	0	0	0	0	0	0	500	online	17.007	79.00481	\N	2026-11-02 09:16:43.604+05:30	\N	f	\N	f	t	2026-11-02 09:16:43.684354+05:30	2026-11-02 09:16:43.684354+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000238	00000000-0000-4000-8000-000000000138	00000000-0000-4000-8000-000000009038	5	0	0	0	0	0	0	0	500	online	17.008	79.00494	\N	2026-11-02 09:16:43.838+05:30	\N	f	\N	f	t	2026-11-02 09:16:43.995453+05:30	2026-11-02 09:16:43.995453+05:30	\N	\N	intercity	100	0	0	\N	\N	f
00000000-0000-4000-8000-000000000239	00000000-0000-4000-8000-000000000139	00000000-0000-4000-8000-000000009039	5	0	0	0	0	0	0	0	500	online	17.009	79.00507	\N	2026-11-02 09:16:44.246+05:30	\N	f	\N	f	t	2026-11-02 09:16:44.5766+05:30	2026-11-02 09:16:44.5766+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000240	00000000-0000-4000-8000-000000000140	00000000-0000-4000-8000-000000009040	5	0	0	0	0	0	0	0	500	online	17.01	79.0052	\N	2026-11-02 09:16:44.76+05:30	\N	f	\N	f	t	2026-11-02 09:16:45.067274+05:30	2026-11-02 09:16:45.067274+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000241	00000000-0000-4000-8000-000000000141	00000000-0000-4000-8000-000000009041	5	0	0	0	0	0	0	0	500	online	17.011	79.00533	\N	2026-11-02 09:16:45.394+05:30	\N	f	\N	f	t	2026-11-02 09:16:45.503429+05:30	2026-11-02 09:16:45.503429+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000242	00000000-0000-4000-8000-000000000142	00000000-0000-4000-8000-000000009042	5	0	0	0	0	0	0	0	500	online	17.012	79.00546	\N	2026-11-02 09:16:45.759+05:30	\N	f	\N	f	t	2026-11-02 09:16:45.920183+05:30	2026-11-02 09:16:45.920183+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000243	00000000-0000-4000-8000-000000000143	00000000-0000-4000-8000-000000009043	5	0	0	0	0	0	0	0	500	online	17.013	79.00559	\N	2026-11-02 09:16:46.107+05:30	\N	f	\N	f	t	2026-11-02 09:16:46.277086+05:30	2026-11-02 09:16:46.277086+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000244	00000000-0000-4000-8000-000000000144	00000000-0000-4000-8000-000000009044	5	0	0	0	0	0	0	0	500	offline	17.014	79.00572	\N	2026-11-02 09:16:46.396+05:30	\N	f	\N	f	t	2026-11-02 09:16:46.490348+05:30	2026-11-02 09:16:46.490348+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000245	00000000-0000-4000-8000-000000000145	00000000-0000-4000-8000-000000009045	5	0	0	0	0	0	0	0	500	online	17.015	79.00585	\N	2026-11-02 09:16:46.782+05:30	\N	f	\N	f	t	2026-11-02 09:16:47.058389+05:30	2026-11-02 09:16:47.058389+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000246	00000000-0000-4000-8000-000000000146	00000000-0000-4000-8000-000000009046	5	0	0	0	0	0	0	500	500	online	17.016	79.00598	\N	2026-11-02 09:16:47.263+05:30	\N	f	\N	f	t	2026-11-02 09:16:47.394496+05:30	2026-11-02 09:16:47.394496+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000247	00000000-0000-4000-8000-000000000147	00000000-0000-4000-8000-000000009047	5	0	0	0	0	0	0	0	500	online	17.017	79.00611	\N	2026-11-02 09:16:47.676+05:30	\N	f	\N	f	t	2026-11-02 09:16:47.883975+05:30	2026-11-02 09:16:47.883975+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000248	00000000-0000-4000-8000-000000000148	00000000-0000-4000-8000-000000009048	5	0	0	0	0	0	0	0	500	online	17.018	79.00624	\N	2026-11-02 09:16:47.993+05:30	\N	f	\N	f	t	2026-11-02 09:16:48.16781+05:30	2026-11-02 09:16:48.16781+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000249	00000000-0000-4000-8000-000000000149	00000000-0000-4000-8000-000000009049	5	0	0	0	0	0	0	0	500	online	17.019	79.00637	\N	2026-11-02 09:16:48.435+05:30	\N	f	\N	f	t	2026-11-02 09:16:48.593972+05:30	2026-11-02 09:16:48.593972+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000250	00000000-0000-4000-8000-000000000150	00000000-0000-4000-8000-000000009050	5	0	0	0	0	0	0	0	500	online	17.02	79.0065	\N	2026-11-02 09:16:48.802+05:30	\N	f	\N	f	t	2026-11-02 09:16:48.999325+05:30	2026-11-02 09:16:48.999325+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000251	00000000-0000-4000-8000-000000000151	00000000-0000-4000-8000-000000009051	5	0	0	0	0	0	0	0	500	online	17.021	79.00663	\N	2026-11-02 09:16:49.178+05:30	\N	f	\N	f	t	2026-11-02 09:16:49.300514+05:30	2026-11-02 09:16:49.300514+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000252	00000000-0000-4000-8000-000000000152	00000000-0000-4000-8000-000000009052	5	0	0	0	0	0	0	0	500	online	17.022	79.00676	\N	2026-11-02 09:16:49.413+05:30	\N	f	\N	f	t	2026-11-02 09:16:49.565739+05:30	2026-11-02 09:16:49.565739+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000253	00000000-0000-4000-8000-000000000153	00000000-0000-4000-8000-000000009053	5	0	0	0	0	0	0	0	500	online	17.023	79.00689	\N	2026-11-02 09:16:49.849+05:30	\N	f	\N	f	t	2026-11-02 09:16:50.042371+05:30	2026-11-02 09:16:50.042371+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000254	00000000-0000-4000-8000-000000000154	00000000-0000-4000-8000-000000009054	5	0	0	0	0	0	0	0	500	online	17.024	79.00702	\N	2026-11-02 09:16:50.182+05:30	\N	f	\N	f	t	2026-11-02 09:16:50.318521+05:30	2026-11-02 09:16:50.318521+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000255	00000000-0000-4000-8000-000000000155	00000000-0000-4000-8000-000000009055	5	0	0	0	0	0	0	0	500	offline	17.025	79.00715	\N	2026-11-02 09:16:50.535+05:30	\N	f	\N	f	t	2026-11-02 09:16:50.748061+05:30	2026-11-02 09:16:50.748061+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000256	00000000-0000-4000-8000-000000000156	00000000-0000-4000-8000-000000009056	5	0	0	0	0	0	0	0	500	online	17.026	79.00728	\N	2026-11-02 09:16:50.957+05:30	\N	f	\N	f	t	2026-11-02 09:16:51.128185+05:30	2026-11-02 09:16:51.128185+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000257	00000000-0000-4000-8000-000000000157	00000000-0000-4000-8000-000000009057	5	0	0	0	0	0	0	0	500	online	17.027	79.00741	\N	2026-11-02 09:16:51.311+05:30	\N	f	\N	f	t	2026-11-02 09:16:51.562889+05:30	2026-11-02 09:16:51.562889+05:30	\N	\N	local	100	0	0	\N	\N	f
00000000-0000-4000-8000-000000000258	00000000-0000-4000-8000-000000000158	00000000-0000-4000-8000-000000009058	5	0	0	0	0	0	0	0	500	online	17.028	79.00754	\N	2026-11-02 09:16:51.819+05:30	\N	f	\N	f	t	2026-11-02 09:16:52.012245+05:30	2026-11-02 09:16:52.012245+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000259	00000000-0000-4000-8000-000000000159	00000000-0000-4000-8000-000000009059	5	0	0	0	0	0	0	0	500	online	17.029	79.00767	\N	2026-11-02 09:16:52.243+05:30	\N	f	\N	f	t	2026-11-02 09:16:52.558725+05:30	2026-11-02 09:16:52.558725+05:30	\N	\N	local	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000260	00000000-0000-4000-8000-000000000160	00000000-0000-4000-8000-000000009060	5	0	0	0	0	0	0	0	500	online	17.03	79.0078	\N	2026-11-02 09:16:52.804+05:30	\N	f	\N	f	t	2026-11-02 09:16:52.904393+05:30	2026-11-02 09:16:52.904393+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000202	00000000-0000-4000-8000-000000000102	00000000-0000-4000-8000-000000009002	5	0	0	0	0	0	0	0	500	online	17	79	124	2026-11-02 09:17:37.324751+05:30	\N	f	\N	f	t	2026-11-02 09:16:31.362674+05:30	2026-11-02 09:16:31.362674+05:30	\N	\N	intercity	0	0	0	\N	\N	f
00000000-0000-4000-8000-000000000201	00000000-0000-4000-8000-000000000101	00000000-0000-4000-8000-000000009001	5	0	0	0	0	0	0	0	500	online	16.971	79.00013	\N	2026-11-02 09:16:31.011+05:30	\N	f	\N	f	t	2026-11-02 09:16:31.114021+05:30	2026-11-02 09:16:31.114021+05:30	\N	\N	local	0	0	0	\N	\N	f
\.


--
-- Data for Name: user_devices; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_devices (id) FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.users (id) FROM stdin;
00000000-0000-4000-8000-000000009000
00000000-0000-4000-8000-000000009001
00000000-0000-4000-8000-000000009002
00000000-0000-4000-8000-000000009003
00000000-0000-4000-8000-000000009004
00000000-0000-4000-8000-000000009005
00000000-0000-4000-8000-000000009006
00000000-0000-4000-8000-000000009007
00000000-0000-4000-8000-000000009008
00000000-0000-4000-8000-000000009009
00000000-0000-4000-8000-000000009010
00000000-0000-4000-8000-000000009011
00000000-0000-4000-8000-000000009012
00000000-0000-4000-8000-000000009013
00000000-0000-4000-8000-000000009014
00000000-0000-4000-8000-000000009015
00000000-0000-4000-8000-000000009016
00000000-0000-4000-8000-000000009017
00000000-0000-4000-8000-000000009018
00000000-0000-4000-8000-000000009019
00000000-0000-4000-8000-000000009020
00000000-0000-4000-8000-000000009021
00000000-0000-4000-8000-000000009022
00000000-0000-4000-8000-000000009023
00000000-0000-4000-8000-000000009024
00000000-0000-4000-8000-000000009025
00000000-0000-4000-8000-000000009026
00000000-0000-4000-8000-000000009027
00000000-0000-4000-8000-000000009028
00000000-0000-4000-8000-000000009029
00000000-0000-4000-8000-000000009030
00000000-0000-4000-8000-000000009031
00000000-0000-4000-8000-000000009032
00000000-0000-4000-8000-000000009033
00000000-0000-4000-8000-000000009034
00000000-0000-4000-8000-000000009035
00000000-0000-4000-8000-000000009036
00000000-0000-4000-8000-000000009037
00000000-0000-4000-8000-000000009038
00000000-0000-4000-8000-000000009039
00000000-0000-4000-8000-000000009040
00000000-0000-4000-8000-000000009041
00000000-0000-4000-8000-000000009042
00000000-0000-4000-8000-000000009043
00000000-0000-4000-8000-000000009044
00000000-0000-4000-8000-000000009045
00000000-0000-4000-8000-000000009046
00000000-0000-4000-8000-000000009047
00000000-0000-4000-8000-000000009048
00000000-0000-4000-8000-000000009049
00000000-0000-4000-8000-000000009050
00000000-0000-4000-8000-000000009051
00000000-0000-4000-8000-000000009052
00000000-0000-4000-8000-000000009053
00000000-0000-4000-8000-000000009054
00000000-0000-4000-8000-000000009055
00000000-0000-4000-8000-000000009056
00000000-0000-4000-8000-000000009057
00000000-0000-4000-8000-000000009058
00000000-0000-4000-8000-000000009059
00000000-0000-4000-8000-000000009060
00000000-0000-4000-8000-000000009061
00000000-0000-4000-8000-000000009062
00000000-0000-4000-8000-000000009063
00000000-0000-4000-8000-000000009064
00000000-0000-4000-8000-000000009065
00000000-0000-4000-8000-000000009066
00000000-0000-4000-8000-000000009067
00000000-0000-4000-8000-000000009068
00000000-0000-4000-8000-000000009069
00000000-0000-4000-8000-000000009070
00000000-0000-4000-8000-000000009071
00000000-0000-4000-8000-000000009072
00000000-0000-4000-8000-000000009073
00000000-0000-4000-8000-000000009074
00000000-0000-4000-8000-000000009075
00000000-0000-4000-8000-000000009076
00000000-0000-4000-8000-000000009077
00000000-0000-4000-8000-000000009078
00000000-0000-4000-8000-000000009079
00000000-0000-4000-8000-000000009080
00000000-0000-4000-8000-000000009081
00000000-0000-4000-8000-000000009082
00000000-0000-4000-8000-000000009083
00000000-0000-4000-8000-000000009084
00000000-0000-4000-8000-000000009085
00000000-0000-4000-8000-000000009086
00000000-0000-4000-8000-000000009087
00000000-0000-4000-8000-000000009088
00000000-0000-4000-8000-000000009089
00000000-0000-4000-8000-000000009090
00000000-0000-4000-8000-000000009091
00000000-0000-4000-8000-000000009092
00000000-0000-4000-8000-000000009093
00000000-0000-4000-8000-000000009094
00000000-0000-4000-8000-000000009095
00000000-0000-4000-8000-000000009096
00000000-0000-4000-8000-000000009097
00000000-0000-4000-8000-000000009098
00000000-0000-4000-8000-000000009099
00000000-0000-4000-8000-000000009100
\.


--
-- Name: local_push_capture_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.local_push_capture_id_seq', 60, true);


--
-- Name: admins admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admins
    ADD CONSTRAINT admins_pkey PRIMARY KEY (id);


--
-- Name: dispatch_config dispatch_config_config_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dispatch_config
    ADD CONSTRAINT dispatch_config_config_code_key UNIQUE (config_code);


--
-- Name: dispatch_config dispatch_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dispatch_config
    ADD CONSTRAINT dispatch_config_pkey PRIMARY KEY (id);


--
-- Name: local_push_capture local_push_capture_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_push_capture
    ADD CONSTRAINT local_push_capture_pkey PRIMARY KEY (id);


--
-- Name: order_assignment_logs order_assignment_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_assignment_logs
    ADD CONSTRAINT order_assignment_logs_pkey PRIMARY KEY (id);


--
-- Name: orders orders_order_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_code_key UNIQUE (order_code);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: pricing_config pricing_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pricing_config
    ADD CONSTRAINT pricing_config_pkey PRIMARY KEY (id);


--
-- Name: rider_assignments rider_assignments_order_id_rider_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_assignments
    ADD CONSTRAINT rider_assignments_order_id_rider_id_key UNIQUE (order_id, rider_id);


--
-- Name: rider_assignments rider_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_assignments
    ADD CONSTRAINT rider_assignments_pkey PRIMARY KEY (id);


--
-- Name: rider_kyc rider_kyc_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_kyc
    ADD CONSTRAINT rider_kyc_pkey PRIMARY KEY (id);


--
-- Name: rider_locations rider_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_locations
    ADD CONSTRAINT rider_locations_pkey PRIMARY KEY (rider_id);


--
-- Name: riders riders_kyc_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.riders
    ADD CONSTRAINT riders_kyc_id_key UNIQUE (kyc_id);


--
-- Name: riders riders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.riders
    ADD CONSTRAINT riders_pkey PRIMARY KEY (id);


--
-- Name: riders riders_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.riders
    ADD CONSTRAINT riders_user_id_key UNIQUE (user_id);


--
-- Name: order_assignment_logs unique_order_rider_assignment; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_assignment_logs
    ADD CONSTRAINT unique_order_rider_assignment UNIQUE (order_id, rider_id, assignment_round);


--
-- Name: user_devices user_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_devices
    ADD CONSTRAINT user_devices_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_riders_kyc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_riders_kyc_id ON public.riders USING btree (kyc_id);


--
-- Name: idx_riders_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_riders_user_id ON public.riders USING btree (user_id);


--
-- Name: orders edge_finance_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER edge_finance_guard BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.protect_order_financial_columns();


--
-- Name: orders edge_mode_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER edge_mode_guard BEFORE UPDATE OF rider_id ON public.orders FOR EACH ROW EXECUTE FUNCTION public.enforce_order_rider_service_mode();


--
-- Name: orders edge_state_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER edge_state_guard BEFORE UPDATE OF order_status, rider_id, pickup_otp, delivery_otp ON public.orders FOR EACH ROW EXECUTE FUNCTION public.protect_order_state_columns();


--
-- Name: orders edge_test_commit_fault; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER edge_test_commit_fault AFTER UPDATE ON public.orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.edge_test_commit_fault();


--
-- Name: orders edge_test_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER edge_test_event AFTER UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.edge_test_event();


--
-- Name: rider_assignments edge_test_fault; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER edge_test_fault BEFORE INSERT OR UPDATE ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION public.edge_test_fault();


--
-- Name: riders protect_rider_financial_columns_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_rider_financial_columns_trigger BEFORE UPDATE ON public.riders FOR EACH ROW EXECUTE FUNCTION public.protect_rider_financial_columns();


--
-- Name: rider_locations trg_rider_locations_near_destination_check; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rider_locations_near_destination_check AFTER UPDATE OF current_lat, current_lng ON public.rider_locations FOR EACH ROW EXECUTE FUNCTION public.check_rider_near_destination_from_rider_locations();


--
-- Name: riders trg_riders_gps_bridge_to_rider_locations; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_riders_gps_bridge_to_rider_locations AFTER UPDATE OF current_lat, current_lng ON public.riders FOR EACH ROW WHEN (((old.current_lat IS DISTINCT FROM new.current_lat) OR (old.current_lng IS DISTINCT FROM new.current_lng) OR (old.current_heading IS DISTINCT FROM new.current_heading) OR (old.last_location_updated_at IS DISTINCT FROM new.last_location_updated_at) OR (old.last_active_at IS DISTINCT FROM new.last_active_at))) EXECUTE FUNCTION public.sync_riders_gps_to_rider_locations();


--
-- Name: riders trigger_assign_nearby_orders; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_assign_nearby_orders AFTER UPDATE OF account_status ON public.riders FOR EACH ROW WHEN (((new.account_status = 'online'::public.rider_account_status_enum) AND (old.account_status IS DISTINCT FROM 'online'::public.rider_account_status_enum))) EXECUTE FUNCTION public.assign_nearby_searching_orders_to_rider();


--
-- Name: rider_assignments trigger_enforce_rider_assignment_service_mode; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_enforce_rider_assignment_service_mode BEFORE INSERT ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION public.enforce_rider_assignment_service_mode();


--
-- Name: rider_assignments trigger_prevent_local_ride_assignment_to_busy_rider; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_prevent_local_ride_assignment_to_busy_rider BEFORE INSERT OR UPDATE ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION public.prevent_local_ride_assignment_to_busy_rider();


--
-- Name: riders trigger_prevent_service_mode_switch_during_active_order; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_prevent_service_mode_switch_during_active_order BEFORE UPDATE OF service_mode ON public.riders FOR EACH ROW EXECUTE FUNCTION public.prevent_service_mode_switch_during_active_order();


--
-- Name: rider_assignments trigger_rider_assignment_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_rider_assignment_change AFTER INSERT OR UPDATE OF assignment_status ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION public.on_rider_assignment_change();


--
-- Name: dispatch_config dispatch_config_updated_by_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dispatch_config
    ADD CONSTRAINT dispatch_config_updated_by_admin_id_fkey FOREIGN KEY (updated_by_admin_id) REFERENCES public.admins(id) ON DELETE SET NULL;


--
-- Name: order_assignment_logs order_assignment_logs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_assignment_logs
    ADD CONSTRAINT order_assignment_logs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_assignment_logs order_assignment_logs_rider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_assignment_logs
    ADD CONSTRAINT order_assignment_logs_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE CASCADE;


--
-- Name: orders orders_created_device_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_created_device_record_id_fkey FOREIGN KEY (created_device_record_id) REFERENCES public.user_devices(id) ON DELETE SET NULL;


--
-- Name: orders orders_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id) ON DELETE SET NULL;


--
-- Name: orders orders_pricing_config_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pricing_config_id_fkey FOREIGN KEY (pricing_config_id) REFERENCES public.pricing_config(id) ON DELETE SET NULL;


--
-- Name: orders orders_rider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE SET NULL;


--
-- Name: orders orders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;


--
-- Name: rider_assignments rider_assignments_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_assignments
    ADD CONSTRAINT rider_assignments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: rider_assignments rider_assignments_rider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_assignments
    ADD CONSTRAINT rider_assignments_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE CASCADE;


--
-- Name: rider_kyc rider_kyc_handled_by_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_kyc
    ADD CONSTRAINT rider_kyc_handled_by_admin_id_fkey FOREIGN KEY (handled_by_admin_id) REFERENCES public.admins(id);


--
-- Name: rider_kyc rider_kyc_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_kyc
    ADD CONSTRAINT rider_kyc_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: rider_locations rider_locations_rider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rider_locations
    ADD CONSTRAINT rider_locations_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE CASCADE;


--
-- Name: riders riders_kyc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.riders
    ADD CONSTRAINT riders_kyc_id_fkey FOREIGN KEY (kyc_id) REFERENCES public.rider_kyc(id) ON DELETE CASCADE;


--
-- Name: riders riders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.riders
    ADD CONSTRAINT riders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: riders Allow authenticated users to view online riders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow authenticated users to view online riders" ON public.riders FOR SELECT TO authenticated USING (((account_status = 'online'::public.rider_account_status_enum) OR (( SELECT auth.uid() AS uid) = user_id)));


--
-- Name: rider_locations Allow owner rider or active-order passenger to view rider locat; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow owner rider or active-order passenger to view rider locat" ON public.rider_locations FOR SELECT TO authenticated USING (public.can_read_rider_location(rider_id));


--
-- Name: orders Allow passengers and assigned riders to update orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow passengers and assigned riders to update orders" ON public.orders FOR UPDATE TO authenticated USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))));


--
-- Name: rider_assignments Allow passengers to insert assignments for their own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow passengers to insert assignments for their own orders" ON public.rider_assignments FOR INSERT TO authenticated WITH CHECK ((public.check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::public.intercity_assignment_status_enum, 'rejected'::public.intercity_assignment_status_enum]))));


--
-- Name: rider_assignments Allow passengers to update assignments for their own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow passengers to update assignments for their own orders" ON public.rider_assignments FOR UPDATE TO authenticated USING (public.check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid))) WITH CHECK ((public.check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::public.intercity_assignment_status_enum, 'rejected'::public.intercity_assignment_status_enum]))));


--
-- Name: rider_assignments Allow passengers to view assignments for their own orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow passengers to view assignments for their own orders" ON public.rider_assignments FOR SELECT TO authenticated USING (public.check_is_order_passenger(order_id, ( SELECT auth.uid() AS uid)));


--
-- Name: rider_assignments Allow riders to insert their own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow riders to insert their own assignments" ON public.rider_assignments FOR INSERT TO authenticated WITH CHECK (((EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::public.intercity_assignment_status_enum, 'expired'::public.intercity_assignment_status_enum]))));


--
-- Name: rider_assignments Allow riders to update their own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow riders to update their own assignments" ON public.rider_assignments FOR UPDATE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::public.intercity_assignment_status_enum, 'expired'::public.intercity_assignment_status_enum]))));


--
-- Name: riders Allow riders to update their own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow riders to update their own profile" ON public.riders FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: rider_assignments Allow riders to view their own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow riders to view their own assignments" ON public.rider_assignments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: orders Allow travellers to browse searching intercity orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow travellers to browse searching intercity orders" ON public.orders FOR SELECT TO authenticated USING (((order_status = 'searching'::public.order_status_enum) AND ((order_type)::text ~~ 'intercity%'::text)));


--
-- Name: orders Allow travellers to view orders tied to active intercity reques; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow travellers to view orders tied to active intercity reques" ON public.orders FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM (public.intercity_requests ir
     JOIN public.riders r ON ((r.id = ir.traveller_id)))
  WHERE ((ir.parcel_id = orders.id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (ir.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text, 'expired'::text]))))));


--
-- Name: orders Allow users to view their own or assigned orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Allow users to view their own or assigned orders" ON public.orders FOR SELECT TO authenticated USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) OR public.check_is_order_candidate_rider(id, ( SELECT auth.uid() AS uid))));


--
-- Name: orders Deny direct client orders insert (service-role only); Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Deny direct client orders insert (service-role only)" ON public.orders FOR INSERT TO authenticated WITH CHECK (false);


--
-- Name: riders Riders can update own rider profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Riders can update own rider profile" ON public.riders FOR UPDATE USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: rider_assignments Riders can view own assignments; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Riders can view own assignments" ON public.rider_assignments FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));


--
-- Name: riders Riders can view own rider profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Riders can view own rider profile" ON public.riders FOR SELECT USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: riders Users can view own rider profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can view own rider profile" ON public.riders FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: orders admin_can_select_orders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_can_select_orders ON public.orders FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: riders admin_can_select_riders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_can_select_riders ON public.riders FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: riders admin_can_update_riders; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_can_update_riders ON public.riders FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

--
-- Name: rider_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rider_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: rider_locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rider_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: riders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.riders ENABLE ROW LEVEL SECURITY;

--
-- Name: orders user_can_update_own_order; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_can_update_own_order ON public.orders FOR UPDATE TO authenticated USING (((( SELECT auth.uid() AS uid) = user_id) AND (order_status = 'searching'::public.order_status_enum))) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: SCHEMA auth; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA auth TO anon;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT USAGE ON SCHEMA auth TO service_role;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION email(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.email() TO anon;
GRANT ALL ON FUNCTION auth.email() TO authenticated;
GRANT ALL ON FUNCTION auth.email() TO service_role;


--
-- Name: FUNCTION role(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.role() TO anon;
GRANT ALL ON FUNCTION auth.role() TO authenticated;
GRANT ALL ON FUNCTION auth.role() TO service_role;


--
-- Name: FUNCTION uid(); Type: ACL; Schema: auth; Owner: -
--

GRANT ALL ON FUNCTION auth.uid() TO anon;
GRANT ALL ON FUNCTION auth.uid() TO authenticated;
GRANT ALL ON FUNCTION auth.uid() TO service_role;


--
-- Name: FUNCTION assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode public.partner_service_mode_enum); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode public.partner_service_mode_enum) FROM PUBLIC;
GRANT ALL ON FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode public.partner_service_mode_enum) TO service_role;


--
-- Name: TABLE admins; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.admins TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.admins TO service_role;
GRANT SELECT ON TABLE public.admins TO anon;


--
-- Name: TABLE dispatch_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dispatch_config TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dispatch_config TO service_role;
GRANT SELECT ON TABLE public.dispatch_config TO anon;


--
-- Name: TABLE government_tax_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.government_tax_config TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.government_tax_config TO service_role;
GRANT SELECT ON TABLE public.government_tax_config TO anon;


--
-- Name: TABLE intercity_requests; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.intercity_requests TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.intercity_requests TO service_role;
GRANT SELECT ON TABLE public.intercity_requests TO anon;


--
-- Name: TABLE local_push_capture; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.local_push_capture TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.local_push_capture TO service_role;
GRANT SELECT ON TABLE public.local_push_capture TO anon;


--
-- Name: SEQUENCE local_push_capture_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.local_push_capture_id_seq TO service_role;


--
-- Name: TABLE order_assignment_logs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.order_assignment_logs TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.order_assignment_logs TO service_role;
GRANT SELECT ON TABLE public.order_assignment_logs TO anon;


--
-- Name: TABLE orders; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.orders TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.orders TO service_role;
GRANT SELECT ON TABLE public.orders TO anon;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payments TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.payments TO service_role;
GRANT SELECT ON TABLE public.payments TO anon;


--
-- Name: TABLE pricing_config; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pricing_config TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pricing_config TO service_role;
GRANT SELECT ON TABLE public.pricing_config TO anon;


--
-- Name: TABLE rider_assignments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_assignments TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_assignments TO service_role;
GRANT SELECT ON TABLE public.rider_assignments TO anon;


--
-- Name: TABLE rider_kyc; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_kyc TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_kyc TO service_role;
GRANT SELECT ON TABLE public.rider_kyc TO anon;


--
-- Name: TABLE rider_locations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_locations TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rider_locations TO service_role;
GRANT SELECT ON TABLE public.rider_locations TO anon;


--
-- Name: TABLE riders; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.riders TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.riders TO service_role;
GRANT SELECT ON TABLE public.riders TO anon;


--
-- Name: TABLE user_devices; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_devices TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_devices TO service_role;
GRANT SELECT ON TABLE public.user_devices TO anon;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO service_role;
GRANT SELECT ON TABLE public.users TO anon;


--
-- PostgreSQL database dump complete
--

\unrestrict QwAYy535bokW5L11CzdfbkRv1sODpmt6HFgxXROgGG37ezH48UsThLvwgSbMKUN


--
-- PostgreSQL database dump
--

\restrict 7pJRfuw4TSS8JeI2vYCivV3PeecHmZVbCQh1aelMLYFe5x2FvbyVmgR5Obl7MB6

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    title text,
    body text,
    notification_type text,
    reference_id uuid,
    reference_type text,
    is_read boolean DEFAULT false,
    push_sent boolean DEFAULT false,
    delivery_status text DEFAULT 'pending'::text,
    delivery_error text,
    payload jsonb DEFAULT '{}'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    read_at timestamp with time zone
);


--
-- Name: user_device_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_device_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    fcm_token text,
    device_type text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    device_id text,
    device_model text,
    device_brand text,
    os_version text,
    app_version text,
    last_ip_address inet,
    last_lat double precision,
    last_lng double precision,
    user_device_id uuid
);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: user_device_tokens user_device_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_device_tokens
    ADD CONSTRAINT user_device_tokens_pkey PRIMARY KEY (id);


--
-- Name: notifications trigger_notification_insert; Type: TRIGGER; Schema: public; Owner: -
--

-- The notification trigger is installed by the candidate cutover/native bootstrap.


--
-- PostgreSQL database dump complete
--

\unrestrict 7pJRfuw4TSS8JeI2vYCivV3PeecHmZVbCQh1aelMLYFe5x2FvbyVmgR5Obl7MB6


ALTER TABLE public.intercity_requests ADD COLUMN IF NOT EXISTS id uuid;
