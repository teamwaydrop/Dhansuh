-- Migration: Add get_order_driver_upi_vpa(order_id) for the passenger UPI-intent payment flow.
-- Date: 2026-07-22
--
-- CONTEXT: The passenger's "Pay via UPI" button (added client-side alongside this migration)
-- needs the assigned driver's UPI VPA to build the `upi://pay?pa=...` deep link. That VPA lives
-- in rider_payout_accounts, a table that otherwise only the owning rider (and service role) can
-- read -- it also holds bank account number, IFSC, and beneficiary contact details, none of
-- which should ever be exposed to a passenger. Rather than loosening RLS on that table (which
-- would expose every driver's full payout record to any authenticated user), this function
-- returns only the two fields a passenger legitimately needs (upi_vpa, beneficiary_name), and
-- only for the specific order the calling user is the passenger on.
CREATE OR REPLACE FUNCTION public.get_order_driver_upi_vpa(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'upi_vpa', rpa.upi_vpa,
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

GRANT EXECUTE ON FUNCTION public.get_order_driver_upi_vpa(uuid) TO authenticated;
