-- Migration: Atomic rider wallet/earnings credit on order completion.
-- Date: 2026-07-24
--
-- CONTEXT: update-order-status's "completed"/"delivered" handler credited a rider's wallet with a
-- JS-side read-then-write: SELECT wallet_balance/total_earnings/... into `rider`, compute new
-- totals in JS, then UPDATE the whole row. Two orders completing for the same rider close together
-- (e.g. two deliveries finishing within the same second) can both read the same starting balance
-- and both write back, silently dropping one of the two credits -- a real "inconsistent wallet
-- balance" bug, not a workaround-able one. This function does the whole credit as a single atomic
-- `column = column + delta` UPDATE, which Postgres serializes correctly per-row, so no completion
-- can ever clobber another's credit regardless of timing.
CREATE OR REPLACE FUNCTION public.credit_rider_for_completed_order(
    p_rider_id uuid,
    p_rider_earning numeric,
    p_is_direct_collection boolean,
    p_company_cod_share numeric
)
RETURNS void AS $$
BEGIN
    UPDATE public.riders
    SET
        total_orders = COALESCE(total_orders, 0) + 1,
        total_completed_orders = COALESCE(total_completed_orders, 0) + 1,
        total_earnings = COALESCE(total_earnings, 0) + p_rider_earning,
        today_earnings = COALESCE(today_earnings, 0) + p_rider_earning,
        wallet_balance = COALESCE(wallet_balance, 0)
            + (CASE WHEN p_is_direct_collection THEN 0 ELSE p_rider_earning END),
        cod_pending_amount = COALESCE(cod_pending_amount, 0)
            + (CASE WHEN p_is_direct_collection THEN p_company_cod_share ELSE 0 END),
        updated_at = now()
    WHERE id = p_rider_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rider record not found for ID: %', p_rider_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.credit_rider_for_completed_order(uuid, numeric, boolean, numeric) TO service_role;
