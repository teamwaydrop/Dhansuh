-- Migration: server-side RPC for the intercity Travel Together mutual handover confirmation.
-- Date: 2026-07-30
--
-- ROOT CAUSE: order_chat_screen.dart's _confirmHandover() (lines 682-716) writes
-- intercity_requests.metadata directly (fine, unrelated to this lockdown), but once BOTH
-- sender_handover_confirmed and rider_handover_confirmed are true (computed client-side from its
-- own write), it ALSO writes orders.order_status directly to 'ongoing'/'picked_up' -- the last
-- remaining authenticated-role direct writer of orders.order_status in the app. Also has no
-- participant check (any authenticated user could call this against any order_id) and trusts its
-- own client-side "both flags are true" computation rather than re-reading the authoritative row.
--
-- Fix: confirm_intercity_handover() derives which flag to set (sender vs. rider) from auth.uid()
-- itself -- never a client-supplied actor type -- verifies the caller is actually a participant on
-- the order, and re-reads both flags from the just-written row before ever transitioning
-- order_status, instead of trusting a client-computed "both are true" claim.

CREATE OR REPLACE FUNCTION public.confirm_intercity_handover(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_order RECORD;
    v_rider RECORD;
    v_request RECORD;
    v_is_sender boolean;
    v_is_rider boolean;
    v_flag_key text;
    v_metadata jsonb;
    v_sender_confirmed boolean;
    v_rider_confirmed boolean;
    v_new_status text;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    SELECT * INTO v_rider FROM public.riders WHERE id = v_order.rider_id;

    v_is_sender := (v_order.user_id = auth.uid());
    v_is_rider := (v_rider.user_id IS NOT NULL AND v_rider.user_id = auth.uid());

    IF NOT (v_is_sender OR v_is_rider) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Not a participant on this order.');
    END IF;

    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE parcel_id = p_order_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'No linked booking found for this order.');
    END IF;

    v_flag_key := CASE WHEN v_is_sender THEN 'sender_handover_confirmed' ELSE 'rider_handover_confirmed' END;
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(v_flag_key, true);

    UPDATE public.intercity_requests
    SET metadata = v_metadata, updated_at = v_now
    WHERE id = v_request.id;

    v_sender_confirmed := COALESCE((v_metadata->>'sender_handover_confirmed')::boolean, false);
    v_rider_confirmed := COALESCE((v_metadata->>'rider_handover_confirmed')::boolean, false);

    -- Only transition once BOTH flags are genuinely true (re-read from the row this function
    -- itself just wrote, never trusted from the client) and the order hasn't already moved past
    -- this point -- makes a repeat call from either party after the transition already happened a
    -- harmless no-op instead of erroring.
    IF v_sender_confirmed AND v_rider_confirmed
       AND v_order.order_status::text NOT IN ('ongoing', 'picked_up', 'rider_at_drop', 'payment_pending', 'completed', 'delivered')
    THEN
        v_new_status := CASE WHEN v_request.booking_type = 'ride' THEN 'ongoing' ELSE 'picked_up' END;
        UPDATE public.orders
        SET order_status = v_new_status::public.order_status_enum,
            picked_up_at = v_now,
            updated_at = v_now
        WHERE id = p_order_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'sender_confirmed', v_sender_confirmed,
        'rider_confirmed', v_rider_confirmed
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.confirm_intercity_handover(uuid) TO authenticated;
