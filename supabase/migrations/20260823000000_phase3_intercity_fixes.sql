-- Migration: Phase 3 backend fixes for Issues 1, 5, and 6 (post-APK real-device bug reports).
-- Each sub-section is independent and additive; none touch RLS policies, financial guards, or
-- complete_intercity_parcel_delivery()'s settlement logic.

-- =====================================================================================
-- ISSUE 1 — defensive grant for the rider-freed rematch RPC.
--
-- ROOT CAUSE (best available without live DB/log access): the async trigger
-- assign_nearby_searching_orders_on_rider_freed() (20260809000001_async_rider_freed_rematch.sql)
-- calls assign_nearby_searching_orders_core() via a service-role-authenticated PostgREST RPC
-- request. That migration's own comment claims the function was "confirmed live" EXECUTE-granted
-- to PUBLIC at write time, so no explicit GRANT was added -- unlike its sibling
-- send_order_status_notifications_core (20260810000000_async_order_status_notifications.sql),
-- which needed an explicit grant after an identical gap was found live for that function. This
-- statement is additive/idempotent (a no-op if the grant already exists) and closes the one
-- concrete, checkable gap this investigation could find without production log/permission access.
-- Client-side, the busy->free forced-refetch fix (rider_orders_screen.dart) is unrelated and
-- already correct -- this is a backend-only hardening.
-- =====================================================================================
GRANT EXECUTE ON FUNCTION public.assign_nearby_searching_orders_core(
    uuid, uuid, double precision, double precision, public.partner_service_mode_enum
) TO service_role;

-- =====================================================================================
-- ISSUE 5 — defer intercity_parcel delivery/completion OTP generation until after the mandatory
-- delivery-proof photo, and stop returning it to the traveller's own client.
--
-- ROOT CAUSE: mark_intercity_trip_at_dropoff() (20260730000008_lock_order_status_and_otp_columns.sql)
-- generated and returned a real delivery_otp unconditionally the instant order_status became
-- 'rider_at_drop' -- before any photo-proof step exists or runs. Both client call sites showed it
-- immediately via SnackBar. regenerate_intercity_delivery_otp() shared the same unconditional-
-- exposure shape, which could otherwise be used to bypass a proof gate placed only on the first
-- function.
--
-- FIX: intercity_parcel no longer receives an OTP from mark_intercity_trip_at_dropoff() at all --
-- it only marks arrival. A new function, generate_intercity_delivery_otp_after_proof(), generates
-- the OTP (and notifies the PASSENGER directly, since this transition doesn't change order_status
-- and so won't fire the generic on_order_status_update trigger) only once a verified/bypassed
-- order_verifications dropoff-photo row exists for the order, and never returns the OTP value in
-- its response. regenerate_intercity_delivery_otp() gets the same photo-proof precondition so it
-- can't be used as a bypass route. intercity_ride behavior (no photo-proof concept exists for
-- rides) is unchanged in both functions.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.mark_intercity_trip_at_dropoff(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_otp text;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text NOT IN ('intercity_ride', 'intercity_parcel') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only applies to intercity Travel Together bookings.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF v_order.order_status::text = 'rider_at_drop' THEN
        RETURN jsonb_build_object(
            'success', true, 'code', 'ALREADY_AT_DROPOFF', 'order_id', v_order.id,
            'delivery_otp', CASE WHEN v_order.order_type::text = 'intercity_ride' THEN v_order.delivery_otp ELSE NULL END
        );
    END IF;

    IF v_order.order_status::text NOT IN ('accepted', 'rider_arrived', 'picked_up') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Trip is not in a state that can be marked at drop-off.');
    END IF;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    IF v_order.order_type::text = 'intercity_parcel' THEN
        -- Issue 5 fix: mark arrival only -- delivery_otp stays NULL here. The traveller's own
        -- client never receives an OTP value from this call for a parcel; see
        -- generate_intercity_delivery_otp_after_proof() below for the gated generation step.
        UPDATE public.orders
        SET order_status = 'rider_at_drop'::public.order_status_enum,
            rider_at_drop_at = now(),
            updated_at = now()
        WHERE id = v_order.id;

        RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id);
    END IF;

    -- intercity_ride: unchanged behavior -- no photo-proof step exists for a ride drop-off, so the
    -- prior "generate immediately" flow is not the bug reported and stays exactly as it was.
    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    UPDATE public.orders
    SET order_status = 'rider_at_drop'::public.order_status_enum,
        delivery_otp = v_otp,
        rider_at_drop_at = now(),
        updated_at = now()
    WHERE id = v_order.id;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.regenerate_intercity_delivery_otp(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_otp text;
    v_has_proof boolean;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text NOT IN ('intercity_ride', 'intercity_parcel') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only applies to intercity Travel Together bookings.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off before requesting a new OTP.');
    END IF;

    -- Issue 5 fix: for a parcel, this now doubles as both "resend" (an OTP already exists) AND the
    -- recovery path if the automatic post-photo generation call failed for any reason -- either
    -- way, the SAME real precondition applies: a verified/bypassed dropoff photo-proof must exist.
    -- This can never be used to bypass that requirement, unlike gating on "was one already
    -- generated" (which could get permanently stuck if the first attempt silently failed).
    IF v_order.order_type::text = 'intercity_parcel' THEN
        SELECT EXISTS (
            SELECT 1 FROM public.order_verifications
            WHERE order_id = p_order_id
              AND verification_type = 'dropoff'
              AND verification_status IN ('verified', 'bypassed')
        ) INTO v_has_proof;

        IF NOT v_has_proof THEN
            RETURN jsonb_build_object('success', false, 'code', 'PROOF_REQUIRED', 'message', 'Delivery proof photo must be completed before an OTP can be resent.');
        END IF;
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET delivery_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    -- Issue 5 fix: notify the passenger with the current OTP on every parcel (re)generation here --
    -- this transition doesn't change order_status so the generic trigger never fires it, and a
    -- passenger holding a now-superseded OTP after a genuine resend is exactly as broken as never
    -- being told the first one. Scoped to intercity_parcel only -- ride's pre-existing resend
    -- behavior (no notification) is unchanged.
    IF v_order.order_type::text = 'intercity_parcel' AND v_order.user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Rider Reached Drop-off 📍',
            'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.',
            jsonb_build_object('type', 'order_status', 'order_id', v_order.id, 'status', 'rider_at_drop')
        );
    END IF;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- New: the gated "first generation" step for intercity_parcel, callable only once a dropoff
-- photo-proof exists. Notifies the passenger directly (reusing the same title/body the generic
-- 'rider_at_drop' notification branch already uses) since no order_status change occurs here to
-- fire that trigger automatically. Deliberately does NOT return delivery_otp -- the calling
-- traveller's client has no way to render a value it was never given.
CREATE OR REPLACE FUNCTION public.generate_intercity_delivery_otp_after_proof(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_otp text;
    v_has_proof boolean;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.order_type::text <> 'intercity_parcel' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This function only applies to intercity parcel deliveries.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off before generating the delivery OTP.');
    END IF;

    -- Idempotent: a retried/duplicate call after the OTP already exists is a safe no-op, not a
    -- silent regeneration (which would invalidate an OTP the passenger may already have been given).
    IF v_order.delivery_otp IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_GENERATED', 'order_id', v_order.id);
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.order_verifications
        WHERE order_id = p_order_id
          AND verification_type = 'dropoff'
          AND verification_status IN ('verified', 'bypassed')
    ) INTO v_has_proof;

    IF NOT v_has_proof THEN
        RETURN jsonb_build_object('success', false, 'code', 'PROOF_REQUIRED', 'message', 'Delivery proof photo must be completed before the OTP can be generated.');
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    PERFORM set_config('app.bypass_order_state_guard', 'true', true);

    UPDATE public.orders
    SET delivery_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    IF v_order.user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Rider Reached Drop-off 📍',
            'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.',
            jsonb_build_object('type', 'order_status', 'order_id', v_order.id, 'status', 'rider_at_drop')
        );
    END IF;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.generate_intercity_delivery_otp_after_proof(uuid) TO authenticated;

-- =====================================================================================
-- ISSUE 6 — Traveller cannot cancel a Travel Plan after accepting a request.
--
-- ROOT CAUSE: cascade_cancel_travel_plan_dependents() (20260729000003, last touched
-- 20260822000000 to tag cancelled_by='rider') writes orders.order_status directly when cascading
-- a plan cancellation to a dependent accepted order, but -- unlike every other legitimate writer
-- of that guarded column -- never sets the app.bypass_order_state_guard flag first.
-- protect_order_state_columns_trigger correctly rejects that write (SECURITY DEFINER does not
-- change auth.role()), aborting the whole cascade and surfacing its generic error text to the
-- user. Fix: add the one missing bypass call, matching the exact pattern already used by
-- mark_intercity_trip_at_dropoff/regenerate_intercity_delivery_otp/complete_intercity_parcel_delivery
-- above. Full function body reproduced byte-for-byte from 20260822000000 otherwise -- no other
-- behavior change. The rider_travel_plans UPDATE RLS policy already correctly scopes cancellation
-- to the plan's own rider, so unauthorized cancellation of another traveller's plan remains blocked
-- exactly as before; nothing here weakens that.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()
RETURNS TRIGGER AS $$
DECLARE
    v_now timestamptz := now();
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN

        -- Every still-open negotiation/booking on this plan -- never a row already in a terminal
        -- state (completed/cancelled/rejected/expired), and never in_progress (the guard above
        -- already refused the update if one exists).
        UPDATE public.intercity_requests
        SET status = 'cancelled',
            metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('cancelled_reason', 'travel_plan_cancelled'),
            updated_at = v_now
        WHERE route_id = NEW.id
          AND status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');

        -- Issue 6 fix: this trigger's own inner UPDATE below (order_status/cancelled_by) needs the
        -- same bypass every other legitimate writer of these guarded columns already sets.
        PERFORM set_config('app.bypass_order_state_guard', 'true', true);

        -- The underlying order for each request just cancelled above, but only if it's still this
        -- exact plan's own rider and still sitting at 'accepted' (never touches an order that has
        -- already moved past acceptance under some other status, or belongs to a different rider).
        UPDATE public.orders o
        SET order_status = 'cancelled'::public.order_status_enum,
            cancelled_at = v_now,
            cancel_reason = 'Traveller cancelled the travel plan.',
            cancelled_by = 'rider',
            updated_at = v_now
        FROM public.intercity_requests ir
        WHERE ir.route_id = NEW.id
          AND ir.parcel_id = o.id
          AND ir.status = 'cancelled'
          AND o.order_status = 'accepted'
          AND o.rider_id = NEW.rider_id;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        SELECT o.id, 'accepted', 'cancelled', 'system_travel_plan_cancelled',
               'Cancelled because the linked travel plan was cancelled by the traveller.'
        FROM public.orders o
        WHERE o.rider_id = NEW.rider_id
          AND o.order_status = 'cancelled'
          AND o.cancelled_at = v_now
          AND EXISTS (
              SELECT 1 FROM public.intercity_requests ir
              WHERE ir.route_id = NEW.id AND ir.parcel_id = o.id AND ir.status = 'cancelled'
          );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
