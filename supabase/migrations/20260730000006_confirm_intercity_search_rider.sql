-- Migration: server-side RPC for a passenger confirming which rider (among possibly several who
-- expressed interest) they accept for an intercity searching order.
-- Date: 2026-07-30
--
-- ROOT CAUSE: intercity_searching_screen.dart's confirmRider() (lines 854-918) writes
-- orders.rider_id/order_status directly, then updates rider_assignments in two more separate
-- client-side calls -- with NO ownership check (any authenticated user could target any order_id),
-- no row lock (a race between two concurrent confirmations for different rider offers on the same
-- order isn't prevented), and no order_status precondition check (works even if the order already
-- left 'searching'). This is also the last remaining "authenticated" direct writer of
-- orders.order_status/rider_id in the app (every other one was either a fallback removed in this
-- same deploy, or was already routed through cancel-order/accept-order/accept_intercity_request),
-- which is what makes locking those two columns down safe -- see
-- 20260730000007_lock_order_status_and_otp_columns.sql.

CREATE OR REPLACE FUNCTION public.confirm_intercity_search_rider(
    p_order_id uuid,
    p_rider_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_order RECORD;
    v_now timestamptz := now();
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.user_id IS DISTINCT FROM auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This order does not belong to you.');
    END IF;

    -- Idempotent: a repeat confirm for the exact same rider that already succeeded is a harmless
    -- no-op success (e.g. a client retry after a dropped response).
    IF v_order.order_status::text = 'accepted' AND v_order.rider_id = p_rider_id THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_CONFIRMED', 'order_id', v_order.id);
    END IF;

    IF v_order.order_status::text <> 'searching' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'This order is no longer searching for a rider.');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.rider_assignments
        WHERE order_id = p_order_id AND rider_id = p_rider_id AND assignment_status IN ('sent', 'accepted')
    ) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This rider has not offered on this order.');
    END IF;

    UPDATE public.orders
    SET rider_id = p_rider_id,
        order_status = 'accepted'::public.order_status_enum,
        accepted_at = v_now,
        updated_at = v_now
    WHERE id = p_order_id
      AND order_status = 'searching';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'CONFLICT', 'message', 'Order status changed by another request. Please retry.');
    END IF;

    UPDATE public.rider_assignments
    SET assignment_status = 'accepted', responded_at = v_now, updated_at = v_now
    WHERE order_id = p_order_id AND rider_id = p_rider_id;

    UPDATE public.rider_assignments
    SET assignment_status = 'rejected', responded_at = v_now, updated_at = v_now
    WHERE order_id = p_order_id AND rider_id IS DISTINCT FROM p_rider_id AND assignment_status = 'sent';

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id, 'rider_id', p_rider_id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.confirm_intercity_search_rider(uuid, uuid) TO authenticated;
