-- Migration: move the rider-freed rematch scan off the synchronous order-completion/cancellation
-- transaction.
--
-- ROOT CAUSE (production DB-contention investigation, 2026-08-07, proven via EXPLAIN ANALYZE +
-- live pg_get_triggerdef inspection): every UPDATE of orders.order_status fires 6 triggers
-- synchronously, one of which -- trigger_assign_nearby_orders_on_rider_freed
-- (20260808000000_reassign_orders_when_rider_freed.sql) -- calls
-- assign_nearby_searching_orders_core(), a full scan+match+insert, INSIDE the same statement that
-- update-order-status's completion/cancellation UPDATE and cancel-order's proxied UPDATE were
-- already found timing out on (live Postgres logs: multiple `57014 canceling statement due to
-- statement timeout` entries on this exact UPDATE, role authenticator, 2026-08-07 16:09-16:15
-- UTC). This is the proven direct cause of "Ride Complete returns 500" / "Cancel Ride hangs".
--
-- FIX: the trigger's WHEN clause and firing condition are unchanged -- it still fires on exactly
-- the same rider-freed transition. Only the function body changes: instead of running the match
-- inline (PERFORM assign_nearby_searching_orders_core(...)), it enqueues an async HTTP call to the
-- SAME function via its existing PostgREST RPC endpoint (assign_nearby_searching_orders_core is
-- already EXECUTE-granted to PUBLIC, confirmed live), using the exact net.http_post + vault-secret
-- pattern already proven in production by redispatch_stalled_searching_orders()
-- (20260808000003_redispatch_stalled_searching_orders_cron.sql). Same matching function, same
-- eligibility rules, same arguments, same result -- the ONLY change is that it now runs a moment
-- after this transaction commits (typically well under a second, pg_net's queue is processed by a
-- dedicated background worker) instead of inside it, so it no longer adds its cost to the
-- statement update-order-status/cancel-order were timing out on. Best-effort: if the async enqueue
-- itself fails for any reason, it's logged (RAISE WARNING), never thrown -- it must never block the
-- order's own completion/cancellation, exactly as it never did before (this trigger only ever
-- affected finding the rider's *next* match, never this transaction's own outcome).

CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_on_rider_freed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rider RECORD;
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    IF NEW.rider_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, account_status, current_lat, current_lng, service_mode
    INTO v_rider
    FROM public.riders
    WHERE id = NEW.rider_id;

    IF NOT FOUND OR v_rider.account_status IS DISTINCT FROM 'online'::public.rider_account_status_enum THEN
        RETURN NEW;
    END IF;

    BEGIN
        SELECT decrypted_secret INTO v_service_role_key
        FROM vault.decrypted_secrets
        WHERE name = 'supabase_service_role_key'
        LIMIT 1;

        IF v_service_role_key IS NOT NULL THEN
            PERFORM net.http_post(
                url := v_supabase_url || '/rest/v1/rpc/assign_nearby_searching_orders_core',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || v_service_role_key,
                    'apikey', v_service_role_key
                ),
                body := jsonb_build_object(
                    'p_rider_id', v_rider.id,
                    'p_rider_user_id', v_rider.user_id,
                    'p_current_lat', v_rider.current_lat,
                    'p_current_lng', v_rider.current_lng,
                    'p_service_mode', v_rider.service_mode
                ),
                timeout_milliseconds := 5000
            );
        ELSE
            RAISE WARNING 'assign_nearby_searching_orders_on_rider_freed: vault secret "supabase_service_role_key" is not configured -- skipping async rematch for rider %', v_rider.id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Never block the order's own completion/cancellation on the async enqueue itself failing
        -- -- the 15s redispatch cron (redispatch_stalled_searching_orders) and the next
        -- online-transition/new-order trigger remain independent backstops for this rider's next
        -- match either way.
        RAISE WARNING 'assign_nearby_searching_orders_on_rider_freed: failed to enqueue async rematch for rider %: %', v_rider.id, SQLERRM;
    END;

    RETURN NEW;
END;
$function$;
