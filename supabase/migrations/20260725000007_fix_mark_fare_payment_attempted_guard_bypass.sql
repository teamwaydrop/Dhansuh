-- Migration: Re-fix mark_fare_payment_attempted's protect_order_financial_columns bypass, which
-- 20260725000005 silently dropped again when it CREATE OR REPLACE'd the function to add 'cash' and
-- drop the `payment_mode = 'online'` restriction.
-- Date: 2026-07-25
--
-- ROOT CAUSE: 20260725000002 added `PERFORM set_config('app.bypass_financial_guard', 'true', true);`
-- to mark_fare_payment_attempted() so its own UPDATE of fare_payment_method (a protected column,
-- see protect_order_financial_columns) is recognized as an already-authorized SECURITY DEFINER RPC
-- call rather than a raw client PATCH. 20260725000005's CREATE OR REPLACE was based on the function
-- body from BEFORE that fix, so the bypass call was lost a second time -- every call has been
-- raising "Direct modification of order financial columns is not permitted." (caught and silently
-- swallowed by the Flutter client's try/catch, never surfaced to the user).
--
-- Fix: restore the bypass call. Everything else (allowed methods, no payment_mode restriction)
-- stays exactly as 20260725000005 defined it.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.mark_fare_payment_attempted(p_order_id uuid, p_method text)
RETURNS jsonb AS $$
DECLARE
    v_updated public.orders;
BEGIN
    IF p_method NOT IN ('personal_upi', 'cashfree', 'cash') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid fare payment method.');
    END IF;

    -- Transaction-local only (third arg `true`) -- never leaks to other statements/connections.
    -- Same pattern confirm_intercity_booking() uses to legitimately write these guarded columns
    -- as an already-authorized SECURITY DEFINER RPC.
    PERFORM set_config('app.bypass_financial_guard', 'true', true);

    UPDATE public.orders
    SET fare_payment_attempted_at = COALESCE(fare_payment_attempted_at, now()),
        fare_payment_method = p_method::public.fare_payment_method_enum
    WHERE id = p_order_id
      AND user_id = auth.uid()
      AND order_status = 'payment_pending'::public.order_status_enum
    RETURNING * INTO v_updated;

    IF v_updated.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Order not eligible for a fare payment attempt.');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'fare_payment_attempted_at', v_updated.fare_payment_attempted_at,
        'fare_payment_method', v_updated.fare_payment_method
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
