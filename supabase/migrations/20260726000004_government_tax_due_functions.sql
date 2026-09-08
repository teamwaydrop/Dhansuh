-- =============================================================================
-- GOVERNMENT TAX DUE: server-authoritative functions.
-- Schema: 20260726000003_government_tax_due_schema.sql
--
-- Rounding rule (documented once, applied everywhere in this feature): tax_amount is always
-- ROUND(taxable_base * rate_percent / 100.0, 2) -- PostgreSQL NUMERIC ROUND, which rounds half
-- away from zero (standard commercial rounding), matching the rounding style
-- calculate_fare_breakdown() already uses elsewhere in this schema. All money math here uses
-- NUMERIC throughout -- no floating point.
-- =============================================================================

-- =====================================================================
-- 1. Active blocking threshold, with a fail-safe default matching the initial business
--    configuration (₹100) if the config table is ever empty.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_active_tax_due_threshold()
RETURNS numeric AS $$
    SELECT COALESCE(
        (SELECT threshold_amount FROM public.government_tax_config WHERE is_active = true ORDER BY updated_at DESC LIMIT 1),
        100.0
    );
$$ LANGUAGE sql STABLE
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_active_tax_due_threshold() TO authenticated, service_role;

-- =====================================================================
-- 2. Single source of truth for "is this rider currently blocked from new order assignments".
--    >= threshold blocks (not >), per spec: ₹99.99 allowed, ₹100.00 blocked. Called from every
--    assignment/acceptance path below -- never re-implemented inline, so there is exactly one
--    place this comparison can ever drift.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.is_rider_blocked_by_tax_due(p_rider_id uuid)
RETURNS boolean AS $$
    SELECT COALESCE(
        (SELECT government_tax_due_balance FROM public.riders WHERE id = p_rider_id),
        0
    ) >= public.get_active_tax_due_threshold();
$$ LANGUAGE sql STABLE
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.is_rider_blocked_by_tax_due(uuid) TO authenticated, service_role;

-- =====================================================================
-- 3. apply_order_government_tax(): called once per legitimately completed order (from
--    update-order-status, inside the same "completed"/"delivered" branch that already calls
--    credit_rider_for_completed_order -- never from payment_pending, a UPI-app open, or a Cash
--    selection). Idempotent: a retried/duplicate call for the same order_id is a no-op that
--    returns the previously-recorded amount instead of creating a second liability -- enforced at
--    the DB level by idx_gov_tax_ledger_one_order_tax_per_order, not merely by this function's own
--    existence check (belt and suspenders against a race between two concurrent completion
--    attempts for the same order).
--
--    Service classification (order_type -> service_category), decided once, here, in the only
--    place this mapping exists:
--      'ride', 'ride_sharing'                                              -> local_passenger_ride
--      'local_parcel', 'batch_delivery', 'food_delivery', 'grocery_delivery',
--      'intercity_parcel'                                                  -> parcel_delivery
--      'intercity_ride'                                                    -> UNRESOLVED (see below)
--
--    'intercity_ride' is deliberately left unclassified: it is passenger transportation, but not
--    "local" -- the only two configured categories request-scoped for this feature are "Local
--    passenger ride" and "Parcel/delivery service", and neither unambiguously describes an
--    intercity passenger trip. Rather than silently guess 5% or 18% for it, this function returns
--    applied:false and creates no liability, logging a NOTICE so this is visible in function logs
--    for a human to resolve by adding an 'intercity_ride' category (with its own rate) to
--    tax_rate_config once the business confirms it -- no code change would be required to activate
--    it, just a config row.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.apply_order_government_tax(
    p_order_id uuid,
    p_rider_id uuid,
    p_order_type text,
    p_taxable_base numeric,
    p_is_direct_collection boolean
)
RETURNS jsonb AS $$
DECLARE
    v_category text;
    v_rate numeric;
    v_tax_amount numeric;
    v_existing record;
BEGIN
    -- Idempotency fast-path: already applied for this order (any retry/duplicate completion call).
    SELECT amount, service_category, rate_percent INTO v_existing
    FROM public.government_tax_ledger
    WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX';

    IF FOUND THEN
        RETURN jsonb_build_object(
            'applied', true,
            'already_existed', true,
            'tax_amount', v_existing.amount,
            'service_category', v_existing.service_category,
            'rate_percent', v_existing.rate_percent
        );
    END IF;

    v_category := CASE
        WHEN p_order_type IN ('ride', 'ride_sharing') THEN 'local_passenger_ride'
        WHEN p_order_type IN ('local_parcel', 'batch_delivery', 'food_delivery', 'grocery_delivery', 'intercity_parcel') THEN 'parcel_delivery'
        ELSE NULL -- includes 'intercity_ride' and anything not explicitly classified above
    END;

    IF v_category IS NULL THEN
        RAISE NOTICE 'apply_order_government_tax: order % (type=%) has no resolved tax category -- no liability created. Needs business classification.', p_order_id, p_order_type;
        RETURN jsonb_build_object('applied', false, 'reason', 'unclassified_order_type', 'order_type', p_order_type);
    END IF;

    IF p_taxable_base IS NULL OR p_taxable_base <= 0 THEN
        RAISE NOTICE 'apply_order_government_tax: order % has no positive taxable_base (%) -- no liability created.', p_order_id, p_taxable_base;
        RETURN jsonb_build_object('applied', false, 'reason', 'no_taxable_base');
    END IF;

    SELECT rate_percent INTO v_rate
    FROM public.tax_rate_config
    WHERE service_category = v_category
      AND is_active = true
      AND effective_from <= now()
    ORDER BY effective_from DESC
    LIMIT 1;

    IF v_rate IS NULL THEN
        RAISE NOTICE 'apply_order_government_tax: no active tax_rate_config row for category % -- no liability created for order %.', v_category, p_order_id;
        RETURN jsonb_build_object('applied', false, 'reason', 'no_active_rate_config', 'service_category', v_category);
    END IF;

    v_tax_amount := ROUND(p_taxable_base * v_rate / 100.0, 2);

    -- Insert the liability. ON CONFLICT DO NOTHING is the DB-level backstop against a genuine
    -- concurrent duplicate call (the SELECT check above already caught the common sequential-retry
    -- case) -- if this loses the race, re-read what the winner recorded and return that instead of
    -- erroring.
    INSERT INTO public.government_tax_ledger (
        rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount
    ) VALUES (
        p_rider_id, p_order_id, 'ORDER_TAX', v_category, p_taxable_base, v_rate, v_tax_amount
    )
    ON CONFLICT (order_id) WHERE entry_type = 'ORDER_TAX' DO NOTHING;

    IF NOT FOUND THEN
        SELECT amount, service_category, rate_percent INTO v_existing
        FROM public.government_tax_ledger
        WHERE order_id = p_order_id AND entry_type = 'ORDER_TAX';

        RETURN jsonb_build_object(
            'applied', true,
            'already_existed', true,
            'tax_amount', v_existing.amount,
            'service_category', v_existing.service_category,
            'rate_percent', v_existing.rate_percent
        );
    END IF;

    IF p_is_direct_collection THEN
        -- Personal QR / Cash: WayDrop never held this fare, so the tax becomes a genuine
        -- outstanding liability the Drop Partner owes separately.
        UPDATE public.riders
        SET government_tax_due_balance = government_tax_due_balance + v_tax_amount,
            updated_at = now()
        WHERE id = p_rider_id;
    ELSE
        -- Cashfree-collected: the caller (update-order-status) withholds this same amount from the
        -- rider_earning it credits to the wallet, so nothing is actually owed on top of that --
        -- record the offsetting entry for auditability ("tax was created, and here is exactly how
        -- it was recovered") without touching the cached balance a second time.
        INSERT INTO public.government_tax_ledger (
            rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount
        ) VALUES (
            p_rider_id, p_order_id, 'ORDER_TAX_WITHHELD', v_category, p_taxable_base, v_rate, -v_tax_amount
        )
        ON CONFLICT (order_id) WHERE entry_type = 'ORDER_TAX_WITHHELD' DO NOTHING;
    END IF;

    RETURN jsonb_build_object(
        'applied', true,
        'already_existed', false,
        'tax_amount', v_tax_amount,
        'service_category', v_category,
        'rate_percent', v_rate
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.apply_order_government_tax(uuid, uuid, text, numeric, boolean) TO service_role;

-- =====================================================================
-- 4. apply_government_tax_payment(): called only after cashfree-webhook/verify-payment confirm a
--    real Cashfree SUCCESS for a payment_for='tax_due' payment. Idempotent via
--    idx_gov_tax_ledger_one_payment_per_payment_id -- a duplicate webhook delivery, or a
--    webhook/verify-payment race on the same payment row, both resolve to "the payment credit was
--    already recorded" rather than double-applying it.
--
--    Concurrency: the balance decrement is an atomic `column = column + delta` UPDATE (delta is
--    negative here), the same safe pattern as credit_rider_for_completed_order -- never a
--    read-then-write. A tax liability from a ride completing mid-payment and this payment credit
--    can interleave in either order and the final balance is correct either way (e.g. due=120,
--    payment of 120 starts, a ride adds +10 making due=130, payment confirms -120 -> due=10).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.apply_government_tax_payment(
    p_rider_id uuid,
    p_payment_id uuid,
    p_amount numeric
)
RETURNS jsonb AS $$
DECLARE
    v_existing record;
    v_new_balance numeric;
BEGIN
    SELECT amount INTO v_existing
    FROM public.government_tax_ledger
    WHERE payment_id = p_payment_id AND entry_type = 'TAX_PAYMENT';

    IF FOUND THEN
        SELECT government_tax_due_balance INTO v_new_balance FROM public.riders WHERE id = p_rider_id;
        RETURN jsonb_build_object('applied', true, 'already_existed', true, 'amount', -v_existing.amount, 'new_balance', v_new_balance);
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'apply_government_tax_payment: amount must be positive (got %)', p_amount;
    END IF;

    INSERT INTO public.government_tax_ledger (rider_id, payment_id, entry_type, amount)
    VALUES (p_rider_id, p_payment_id, 'TAX_PAYMENT', -p_amount)
    ON CONFLICT (payment_id) WHERE entry_type = 'TAX_PAYMENT' DO NOTHING;

    IF NOT FOUND THEN
        SELECT amount INTO v_existing FROM public.government_tax_ledger
        WHERE payment_id = p_payment_id AND entry_type = 'TAX_PAYMENT';
        SELECT government_tax_due_balance INTO v_new_balance FROM public.riders WHERE id = p_rider_id;
        RETURN jsonb_build_object('applied', true, 'already_existed', true, 'amount', -v_existing.amount, 'new_balance', v_new_balance);
    END IF;

    UPDATE public.riders
    SET government_tax_due_balance = government_tax_due_balance - p_amount,
        updated_at = now()
    WHERE id = p_rider_id
    RETURNING government_tax_due_balance INTO v_new_balance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'apply_government_tax_payment: rider % not found', p_rider_id;
    END IF;

    RETURN jsonb_build_object('applied', true, 'already_existed', false, 'amount', p_amount, 'new_balance', v_new_balance);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.apply_government_tax_payment(uuid, uuid, numeric) TO service_role;

-- =====================================================================
-- 5. find_nearby_riders(): add the threshold gate to the existing eligibility filter. Base
--    definition: 20260718000010 (service-mode enforcement). Every other line preserved
--    byte-for-byte; only the new "AND NOT public.is_rider_blocked_by_tax_due(r.id)" condition is
--    added to the WHERE clause.
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
        -- GOVERNMENT TAX DUE: a rider at/above the configured threshold must not be sent any new
        -- assignment, through this or any other path (see is_rider_blocked_by_tax_due()). Existing
        -- active orders are untouched -- this only ever affects NEW candidate matching.
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

-- =====================================================================
-- 6. assign_nearby_searching_orders_to_rider(): add the same threshold gate. Base definition:
--    20260718000010. A blocked rider's own location/status update must not assign them anything
--    new either -- checked once at the top (before the per-order loop even starts) since it
--    depends only on the updating rider (NEW), not on any individual candidate order.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
RETURNS TRIGGER AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
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
        COALESCE(rider_response_timeout_sec, 120)
    INTO
        v_radius_km,
        v_stale_sec,
        v_timeout_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);

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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 7. accept_intercity_request(): add the same threshold gate. Base definition: 20260721000002
--    (seat-race fix). New step "1c" inserted right after the existing service-mode gate; every
--    other line preserved byte-for-byte.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.accept_intercity_request(
    p_request_id uuid,
    p_rider_user_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_bookings int;
BEGIN
    SELECT * INTO v_rider
    FROM public.riders
    WHERE user_id = p_rider_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Rider profile not found for user.'
        );
    END IF;

    IF v_rider.service_mode IS DISTINCT FROM 'intercity'::public.partner_service_mode_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'WRONG_SERVICE_MODE',
            'message', 'Switch to Intercity Traveller mode to accept this request.'
        );
    END IF;

    -- 1c. GOVERNMENT TAX DUE: a rider at/above the configured threshold cannot accept new work
    -- through this path either -- the block applies to all new assignments, not just local ones.
    IF public.is_rider_blocked_by_tax_due(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TAX_DUE_THRESHOLD_BLOCKED',
            'message', 'New orders are paused because your Government Tax Due has reached the limit. Pay the due amount to continue receiving orders.'
        );
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Intercity request not found.'
        );
    END IF;

    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_request.parcel_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Associated order not found.'
        );
    END IF;

    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid', 'in_progress')
      AND id IS DISTINCT FROM p_request_id;

    IF v_active_bookings >= v_travel_plan.max_bookings THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PLAN_FULLY_BOOKED',
            'message', 'This travel plan is fully booked.'
        );
    END IF;

    IF public.rider_is_on_active_trip(v_rider.id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active trip.'
        );
    END IF;

    IF public.passenger_has_conflicting_trip(
        v_order.user_id,
        v_order.id,
        COALESCE(v_order.travel_date, v_order.created_at),
        COALESCE(v_order.travel_date, v_order.created_at)
            + make_interval(mins => COALESCE(v_order.estimated_duration_min, 240))
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'PASSENGER_ALREADY_CONFIRMED',
            'message', 'Passenger already has a conflicting trip at this time.'
        );
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE pickup_otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        pickup_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    INSERT INTO public.order_chat_messages(
        sender_id,
        sender_type,
        message,
        user_id,
        is_support,
        order_id,
        rider_id,
        created_at
    ) VALUES (
        v_rider.user_id,
        'rider',
        '[AGREED] Rider accepted the request. Booking is confirmed.',
        v_order.user_id,
        false,
        v_order.id,
        v_rider.id,
        now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'request_id', v_request.id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', SQLERRM
        );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
