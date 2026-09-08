-- Migration: safety-net recovery for orders stuck in a non-terminal ACTIVE status, mirroring the
-- existing expire_stale_searching_orders() pattern for 'searching' orders.
--
-- ROOT CAUSE (production stuck-order investigation, 2026-08-07, proven via live data): a rider's
-- availability for new dispatch is entirely derived from find_nearby_riders()'s
-- `NOT EXISTS (orders WHERE rider_id = r.id AND order_status IN (accepted, rider_arrived,
-- picked_up, ongoing))`. 'searching' orders self-heal via expire_stale_searching_orders() (1-min
-- cron) and redispatch_stalled_searching_orders() (15s cron) -- but nothing existed for
-- accepted/rider_arrived/picked_up/ongoing/rider_at_drop/payment_pending. Confirmed live: two real
-- orders stuck in 'accepted' for 6.6 and 17.3 days respectively, permanently excluding their
-- riders from ALL future dispatch with no recovery path.
--
-- FIX: a new, narrowly-scoped cron job that only ever touches an order once it has had zero
-- activity (no order_status change, i.e. updated_at unchanged) for 24 straight hours -- far beyond
-- any genuine local or intercity trip duration, so this can only ever catch an order that has
-- already been abandoned (app crash, rider/passenger walked away mid-flow, a transition that
-- silently failed, etc.), never a real active ride. Sets order_status = 'cancelled' via the exact
-- same columns (cancel_reason, cancelled_at, updated_at) any other cancellation sets, so it is
-- indistinguishable downstream from a normal cancellation: the SAME existing AFTER UPDATE triggers
-- fire identically either way -- on_order_activity_tracking, trigger_order_status_update (notifies
-- both parties, exactly as any other cancellation does), and (as of the companion migration in
-- this same batch) the rider-freed rematch, which is what actually frees the rider for new
-- dispatch. No pricing, wallet, or payment code path is touched -- cancellation never credits or
-- debits a wallet (only the completed/delivered branch of update-order-status does that).
--
-- Also expires any outstanding rider_assignments left pointing at an order this sweep just
-- cancelled (Dispatch-related lifecycle cleanup: prevents an orphaned 'sent'/'accepted'
-- assignment row from outliving the order it belongs to), mirroring the identical cleanup
-- update-order-status's own 'cancelled' branch already performs for every other cancellation path.

CREATE OR REPLACE FUNCTION public.expire_stale_active_orders()
RETURNS void AS $$
DECLARE
    v_order RECORD;
    v_expired_count integer := 0;
BEGIN
    -- The CTE snapshots each candidate's PRE-update order_status (old_status) before the UPDATE
    -- overwrites it -- unlike expire_stale_searching_orders() (which can hardcode the literal
    -- 'searching' as previous_status, since its WHERE clause matches exactly one starting status),
    -- this sweep matches six different possible starting statuses, so the true prior value has to
    -- be captured explicitly to write a correct order_status_history row.
    FOR v_order IN
        WITH stale AS (
            SELECT id, order_status AS old_status
            FROM public.orders
            WHERE order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop', 'payment_pending')
              AND updated_at < (NOW() - INTERVAL '24 hours')
        )
        UPDATE public.orders o
        SET order_status = 'cancelled',
            cancel_reason = 'Automatically cancelled: no activity for 24+ hours',
            cancelled_at = NOW(),
            updated_at = NOW()
        FROM stale
        WHERE o.id = stale.id
        RETURNING o.id, stale.old_status
    LOOP
        v_expired_count := v_expired_count + 1;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        VALUES (
            v_order.id,
            v_order.old_status,
            'cancelled',
            'system',
            'Auto-cancelled: no activity for 24+ hours (stale active-order recovery).'
        );

        UPDATE public.rider_assignments
        SET assignment_status = 'expired',
            responded_at = NOW(),
            updated_at = NOW()
        WHERE order_id = v_order.id
          AND assignment_status IN ('sent', 'accepted');

        UPDATE public.order_assignment_logs
        SET assignment_status = 'expired',
            responded_at = NOW()
        WHERE order_id = v_order.id
          AND assignment_status IN ('sent', 'accepted');
    END LOOP;

    IF v_expired_count > 0 THEN
        RAISE LOG '[expire_stale_active_orders] Auto-cancelled % stale active order(s) past 24h with no activity.', v_expired_count;
    END IF;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

SELECT cron.schedule(
    'expire-stale-active-orders',
    '*/10 * * * *',
    $$SELECT public.expire_stale_active_orders();$$
);
