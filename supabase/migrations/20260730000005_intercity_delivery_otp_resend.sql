-- Migration: explicit "resend OTP" support for the intercity Travel Together drop-off flow.
-- Date: 2026-07-30
--
-- mark_intercity_trip_at_dropoff() (20260730000004) is deliberately idempotent when called again
-- while already at 'rider_at_drop' -- it returns the EXISTING otp rather than silently rotating it
-- out from under a receiver who might already be looking at it. "Resend OTP" is a distinct,
-- explicit user action that should actually issue a fresh code (invalidating the old one) --
-- replaces the same client-side-weak-OTP direct write _resendOtp() used
-- (intercity_bookings_screen.dart:384-406, same generation algorithm/bug as _markRideArrived).

CREATE OR REPLACE FUNCTION public.regenerate_intercity_delivery_otp(
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

    IF v_order.order_status::text <> 'rider_at_drop' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Mark arrival at drop-off before requesting a new OTP.');
    END IF;

    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        PERFORM 1 FROM public.orders WHERE delivery_otp = v_otp AND order_status = 'rider_at_drop';
        EXIT WHEN NOT FOUND;
    END LOOP;

    UPDATE public.orders
    SET delivery_otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'delivery_otp', v_otp);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.regenerate_intercity_delivery_otp(uuid) TO authenticated;
