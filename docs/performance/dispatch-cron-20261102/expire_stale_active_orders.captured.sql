CREATE OR REPLACE FUNCTION public.expire_stale_active_orders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
