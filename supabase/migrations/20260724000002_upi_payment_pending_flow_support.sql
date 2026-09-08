-- Migration: Support objects for the 'payment_pending' order_status added in
-- 20260724000001. Split into its own file/transaction because a freshly added enum value
-- cannot be referenced in the same transaction that created it.
-- Date: 2026-07-24

-- =====================================================================
-- 1. Track when the passenger was actually shown the UPI payment prompt, so the driver's
--    "Swipe to Confirm UPI Received" step only ever appears after that has genuinely happened
--    (never immediately on the driver's own "swipe to complete" tap).
-- =====================================================================
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS upi_payment_prompted_at timestamptz;

-- =====================================================================
-- 2. mark_upi_payment_prompted(order_id): called by the passenger's app the moment it shows/
--    launches the UPI intent. Restricted to the order's own passenger, and only while the order
--    is actually in payment_pending for a 'upi' order, so it can't be used to fake this signal
--    on someone else's order or at the wrong point in the lifecycle.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.mark_upi_payment_prompted(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_updated public.orders;
BEGIN
    UPDATE public.orders
    SET upi_payment_prompted_at = COALESCE(upi_payment_prompted_at, now())
    WHERE id = p_order_id
      AND user_id = auth.uid()
      AND payment_mode = 'upi'
      AND order_status = 'payment_pending'::public.order_status_enum
    RETURNING * INTO v_updated;

    IF v_updated.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Order not eligible for a UPI payment prompt.');
    END IF;

    RETURN jsonb_build_object('success', true, 'upi_payment_prompted_at', v_updated.upi_payment_prompted_at);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.mark_upi_payment_prompted(uuid) TO authenticated;

-- =====================================================================
-- 3. rider_is_on_active_trip(): a rider whose current order is in payment_pending is still
--    physically mid-handoff (trip has ended, waiting on the passenger's UPI payment before the
--    driver can confirm and free up) and must keep counting as busy for dispatch/matching --
--    same treatment as 'ongoing'. Base definition: 20260720000004. Every other line preserved.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.rider_is_on_active_trip(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
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

COMMENT ON FUNCTION public.rider_is_on_active_trip(uuid) IS
    'Canonical "is this rider busy right now" check. A local order is busy from acceptance; an intercity/long-distance order is only busy once trip_started_at is set (Start Trip pressed), never while merely accepted and Waiting for Travel Day. payment_pending (trip ended, awaiting the passenger''s UPI payment) counts as busy, same as ongoing. Reused by accept_intercity_request, prevent_service_mode_switch_during_active_order, and find_nearby_riders so this rule lives in one place.';
