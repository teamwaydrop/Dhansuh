CREATE OR REPLACE FUNCTION public.expire_stale_searching_orders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_max_search_duration_sec integer;
    v_order RECORD;
    v_expired_count integer := 0;
BEGIN
    SELECT COALESCE(max_search_duration_sec, 900)
    INTO v_max_search_duration_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_max_search_duration_sec := COALESCE(v_max_search_duration_sec, 900);

    FOR v_order IN
        UPDATE public.orders
        SET order_status = 'expired',
            updated_at = NOW()
        WHERE order_status = 'searching'
          AND order_type NOT IN ('intercity_ride', 'intercity_parcel')
          AND created_at < (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
        RETURNING id
    LOOP
        v_expired_count := v_expired_count + 1;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        VALUES (
            v_order.id,
            'searching',
            'expired',
            'system',
            'Auto-expired: no rider accepted within the configured search window.'
        );

        -- Close out any outstanding 'sent' assignment for this order -- it is now moot, and must
        -- never be resettable back to 'sent' by assign_nearby_searching_orders_to_rider() (which is
        -- itself now guarded against this by the companion migration's created_at bound, but closing
        -- it here too keeps rider_assignments/order_assignment_logs consistent with the same
        -- cleanup update-order-status's 'cancelled' branch already performs for every other
        -- terminal-order-state transition).
        UPDATE public.rider_assignments
        SET assignment_status = 'expired',
            responded_at = NOW(),
            updated_at = NOW(),
            response_type = 'ignored'
        WHERE order_id = v_order.id
          AND assignment_status = 'sent';

        UPDATE public.order_assignment_logs
        SET assignment_status = 'expired',
            responded_at = NOW()
        WHERE order_id = v_order.id
          AND assignment_status = 'sent';
    END LOOP;

    IF v_expired_count > 0 THEN
        RAISE LOG '[expire_stale_searching_orders] Expired % order(s) past their % second search window.', v_expired_count, v_max_search_duration_sec;
    END IF;

    -- Independent safety net: expire any 'sent' rider_assignments whose OWN expires_at has passed,
    -- regardless of their order's status (covers assignments a dispatch worker or the client's local
    -- timer never got to close out, e.g. app backgrounded/killed mid-round). Bounded by
    -- idx_rider_assignments_sent_expires_at.
    UPDATE public.rider_assignments
    SET assignment_status = 'expired',
        responded_at = NOW(),
        updated_at = NOW(),
        response_type = 'ignored'
    WHERE assignment_status = 'sent'
      AND expires_at < NOW();
END;
$function$
;
