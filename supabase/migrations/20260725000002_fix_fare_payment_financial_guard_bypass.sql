-- Migration: Fix protect_order_financial_columns() regression that silently blocks
-- mark_fare_payment_attempted() on every call.
-- Date: 2026-07-25
--
-- ROOT CAUSE (confirmed against live production data for order WDRE5YOEF):
-- 20260724000005 introduced a `current_setting('app.bypass_financial_guard', true)` escape hatch
-- in protect_order_financial_columns() specifically so a SECURITY DEFINER RPC invoked by an
-- 'authenticated' caller (confirm_intercity_booking()) can legitimately write protected columns --
-- SECURITY DEFINER does not change what auth.role() reports, so without this bypass the trigger
-- can never tell "a trusted, already-authorized RPC" apart from "a raw direct PATCH".
--
-- 20260725000000 (same day, one migration later) re-created protect_order_financial_columns()
-- to also guard payment_status/fare_payment_method, but based that CREATE OR REPLACE off the
-- ORIGINAL 20260724000004 definition -- silently dropping the bypass clause added in
-- 20260724000005. 20260725000001 then added mark_fare_payment_attempted(), a SECURITY DEFINER RPC
-- called directly by the passenger's app (role 'authenticated') that updates fare_payment_method.
--
-- Net effect: every mark_fare_payment_attempted() call raises "Direct modification of order
-- financial columns is not permitted", caught and silently swallowed by the Flutter client
-- (debugPrint only, never surfaced). fare_payment_attempted_at can never be set. For
-- default_fare_payment_method = 'personal_upi' drivers this is a hard production blocker: the
-- update-order-status completion guard requires fare_payment_attempted_at to be non-null before a
-- personal_upi order can ever be completed (see update-order-status/index.ts).
--
-- Fix: restore the bypass clause, and have mark_fare_payment_attempted() set it before its UPDATE,
-- exactly the same pattern confirm_intercity_booking() already uses.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
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
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.mark_fare_payment_attempted(p_order_id uuid, p_method text)
RETURNS jsonb AS $$
DECLARE
    v_updated public.orders;
BEGIN
    IF p_method NOT IN ('personal_upi', 'cashfree') THEN
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
      AND payment_mode = 'online'
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

GRANT EXECUTE ON FUNCTION public.mark_fare_payment_attempted(uuid, text) TO authenticated;
