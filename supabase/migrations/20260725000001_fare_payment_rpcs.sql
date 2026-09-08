-- Migration: RPCs for driver-preference fare collection.
-- Date: 2026-07-25
-- Depends on 20260725000000_driver_fare_payment_preference.sql (fare_payment_method_enum,
-- rider_payout_accounts.default_fare_payment_method/upi_verified,
-- orders.fare_payment_attempted_at).

-- =====================================================================
-- 1. get_order_driver_fare_payment_info(order_id): replaces get_order_driver_upi_vpa. Same
-- SECURITY DEFINER pattern and same narrow scoping (only the two fields the old function
-- exposed, plus the new method/QR/verified fields) -- still only ever readable by the order's
-- own passenger, never broader access to rider_payout_accounts (bank details, IFSC, etc).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_order_driver_fare_payment_info(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'method', rpa.default_fare_payment_method,
        'upi_vpa', rpa.upi_vpa,
        'upi_verified', rpa.upi_verified,
        'beneficiary_name', rpa.beneficiary_name
    ) INTO v_result
    FROM public.orders o
    JOIN public.rider_payout_accounts rpa ON rpa.rider_id = o.rider_id
    WHERE o.id = p_order_id
      AND o.user_id = auth.uid()
      AND o.rider_id IS NOT NULL;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.get_order_driver_fare_payment_info(uuid) TO authenticated;

-- get_order_driver_upi_vpa is superseded by the function above -- drop it rather than leave a
-- second, narrower way to read the same underlying data (dev rule: no duplicate payment logic).
DROP FUNCTION IF EXISTS public.get_order_driver_upi_vpa(uuid);

-- =====================================================================
-- 2. mark_fare_payment_attempted(order_id, method): generalizes the old
-- mark_upi_payment_prompted to both personal_upi and cashfree -- called by the passenger's app
-- the moment it genuinely launches a UPI app or opens the Cashfree checkout, AND again if the
-- passenger taps "Use backup payment" (switches method from personal_upi to cashfree for the
-- same order). Always (re)writes fare_payment_method to the method actually being attempted right
-- now -- that's what makes the backup-payment switch work -- but only ever sets
-- fare_payment_attempted_at once (first genuine attempt, of either method). Same restriction as
-- before: only the order's own passenger, only while in payment_pending, so it can't be used to
-- fake this signal on someone else's order or at the wrong point in the lifecycle.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.mark_fare_payment_attempted(p_order_id uuid, p_method text)
RETURNS jsonb AS $$
DECLARE
    v_updated public.orders;
BEGIN
    IF p_method NOT IN ('personal_upi', 'cashfree') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid fare payment method.');
    END IF;

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

-- mark_upi_payment_prompted is superseded by the function above for all new 'online' orders.
-- Left in place (not dropped) purely so any already-in-flight legacy payment_mode = 'upi' order
-- from before this change can still complete -- see update-order-status's legacy branch. Drop it
-- in a future cleanup once no such orders remain.

-- =====================================================================
-- 3. set_default_fare_payment_method(method): the driver's own Payment Settings toggle
-- (Personal UPI <-> Cashfree). rider_payout_accounts has no UPDATE RLS policy at all (every other
-- write goes through create-rider-payout with the service-role key) -- rather than opening a
-- broad UPDATE policy on a table that also holds bank account/IFSC, this is a narrow SECURITY
-- DEFINER function that can only ever touch this one column, only on the caller's own row.
-- Refuses to switch TO personal_upi while the VPA on file isn't verified, so a driver can never
-- end up with an unverified/invalid VPA silently becoming their live default.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.set_default_fare_payment_method(p_method text)
RETURNS jsonb AS $$
DECLARE
    v_updated public.rider_payout_accounts;
BEGIN
    IF p_method NOT IN ('personal_upi', 'cashfree') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid fare payment method.');
    END IF;

    IF p_method = 'personal_upi' THEN
        UPDATE public.rider_payout_accounts
        SET default_fare_payment_method = 'personal_upi'::public.fare_payment_method_enum,
            updated_at = now()
        WHERE user_id = auth.uid()
          AND upi_verified = true
        RETURNING * INTO v_updated;

        IF v_updated.id IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Verify your UPI ID before making it your default payment method.'
            );
        END IF;
    ELSE
        UPDATE public.rider_payout_accounts
        SET default_fare_payment_method = 'cashfree'::public.fare_payment_method_enum,
            updated_at = now()
        WHERE user_id = auth.uid()
        RETURNING * INTO v_updated;

        IF v_updated.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'message', 'No payout account found.');
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'default_fare_payment_method', v_updated.default_fare_payment_method
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.set_default_fare_payment_method(text) TO authenticated;
