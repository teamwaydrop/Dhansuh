-- Migration: Final payment architecture -- remove Cashfree UPI-verification dependency,
-- add driver self-certification, and let the passenger choose Cash as a fare-settlement method.
-- Date: 2026-07-25
--
-- CONTEXT: Cashfree's Validate Payout API (the only source of upi_verified=true) requires a
-- separately-licensed "Verification Suite" capability our merchant account does not have (see
-- verify-driver-upi's "Feature not enabled" investigation). Rather than pay for/depend on that,
-- the driver now explicitly self-certifies ownership of their own UPI ID at registration time
-- (Flutter checkbox, enforced server-side by create-rider-payout), and passengers choose their
-- settlement method (UPI Apps / Cash) fresh at payment_pending rather than it being decided by
-- the driver's stored preference + a verification gate.

-- =====================================================================
-- 1. 'cash' becomes a valid fare_payment_method -- the passenger's own choice at payment_pending,
-- recorded via mark_fare_payment_attempted exactly like personal_upi/cashfree already are.
-- =====================================================================
ALTER TYPE public.fare_payment_method_enum ADD VALUE IF NOT EXISTS 'cash';

-- =====================================================================
-- 2. Driver self-certification -- replaces upi_verified/upi_verified_at as the gate on whether
-- personal_upi can ever be offered to a passenger. Set only by create-rider-payout (service role),
-- only when the driver has ticked the ownership-confirmation checkbox in the same request.
-- upi_verified/upi_verified_at are NOT dropped -- they stay as an unused historical record (a
-- genuine past Cashfree verification is still meaningful provenance) rather than risk a
-- destructive column drop.
-- =====================================================================
ALTER TABLE public.rider_payout_accounts
    ADD COLUMN IF NOT EXISTS upi_self_certified boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS upi_self_certified_at timestamptz;

-- Grandfather rows that already went through a GENUINE Cashfree verification (upi_verified_at is
-- only ever set alongside upi_verified=true by verify-driver-upi's own real success branch, never
-- by the manual-bypass path already corrected in 20260725000003) -- a real gateway name-check is
-- at least as strong a provenance signal as a fresh self-certification checkbox.
UPDATE public.rider_payout_accounts
SET upi_self_certified = true,
    upi_self_certified_at = upi_verified_at
WHERE upi_verified = true
  AND upi_verified_at IS NOT NULL
  AND upi_self_certified = false;

-- =====================================================================
-- 3. Extend the write-protection trigger (20260725000003) to also cover upi_self_certified: only
-- the service role may ever set it, mirroring upi_verified. A changed VPA still unconditionally
-- invalidates upi_verified (nothing legitimately re-verifies inline with a VPA change anymore --
-- verify-driver-upi is no longer called). upi_self_certified is deliberately NOT auto-invalidated
-- here: create-rider-payout (the only writer) always requires and re-sets it correctly in the very
-- same statement that changes upi_vpa, so forcing it false first would just fight that -- the
-- RLS lockdown from 20260725000003 (no client UPDATE policy on this table at all) is what actually
-- prevents a VPA change without re-certification from any other path.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_rider_upi_verification()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF auth.role() <> 'service_role' THEN
            IF NEW.upi_verified IS TRUE THEN
                RAISE EXCEPTION 'upi_verified can only be set by the server.';
            END IF;
            IF NEW.upi_self_certified IS TRUE THEN
                RAISE EXCEPTION 'upi_self_certified can only be set by the server.';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.upi_vpa IS DISTINCT FROM OLD.upi_vpa THEN
        NEW.upi_verified := false;
        NEW.upi_verified_at := NULL;
    END IF;

    IF auth.role() <> 'service_role' THEN
        IF NEW.upi_verified IS DISTINCT FROM OLD.upi_verified
           OR NEW.upi_verified_at IS DISTINCT FROM OLD.upi_verified_at THEN
            RAISE EXCEPTION 'upi_verified can only be set by the server.';
        END IF;
        IF NEW.upi_self_certified IS DISTINCT FROM OLD.upi_self_certified
           OR NEW.upi_self_certified_at IS DISTINCT FROM OLD.upi_self_certified_at THEN
            RAISE EXCEPTION 'upi_self_certified can only be set by the server.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 4. mark_fare_payment_attempted: allow 'cash' as a chosen method, and drop the
-- `payment_mode = 'online'` restriction -- every ride now reaches payment_pending regardless of
-- how payment_mode was set at booking (see update-order-status), so a cash-booked ride's
-- passenger must be able to record their in-the-moment choice (UPI Apps / Cash) here too.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.mark_fare_payment_attempted(p_order_id uuid, p_method text)
RETURNS jsonb AS $$
DECLARE
    v_updated public.orders;
BEGIN
    IF p_method NOT IN ('personal_upi', 'cashfree', 'cash') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid fare payment method.');
    END IF;

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

-- =====================================================================
-- 5. set_default_fare_payment_method: gate on upi_self_certified instead of upi_verified. This
-- toggle no longer drives passenger-facing routing (FarePaymentPanel now always offers the same
-- UPI Apps / Cash choice, independent of driver preference) but is left functional/consistent
-- rather than removed, since it is not otherwise broken.
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
          AND upi_self_certified = true
        RETURNING * INTO v_updated;

        IF v_updated.id IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Confirm your UPI ID before making it your default payment method.'
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

-- =====================================================================
-- 6. get_order_driver_fare_payment_info: swap upi_verified for upi_self_certified. Drops the
-- 'method' (default_fare_payment_method) field -- FarePaymentPanel no longer branches on the
-- driver's stored preference, only on whether a self-certified VPA is on file at all.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_order_driver_fare_payment_info(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'upi_vpa', rpa.upi_vpa,
        'upi_self_certified', rpa.upi_self_certified,
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
