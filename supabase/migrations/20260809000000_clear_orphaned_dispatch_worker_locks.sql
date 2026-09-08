-- Migration: defense-in-depth cleanup for dispatch_worker_running left stuck `true` when a
-- start-dispatch worker's Deno isolate is killed by the platform (CPU/wall-time budget, OOM)
-- before its own try/finally (supabase/functions/start-dispatch/index.ts) can execute.
--
-- Confirmed live during the 2026-08-07 production timeout investigation: of orders created in
-- the prior 2 days, 0 were still order_status = 'searching', but 6 still had
-- dispatch_worker_running = true. Those orders will NEVER be revisited by
-- redispatch_stalled_searching_orders() (20260808000003 -- it only scans order_status =
-- 'searching'), so nothing else in the system was ever going to clear that flag once set.
--
-- This is bookkeeping-only: it does NOT re-trigger dispatch, does NOT call start-dispatch, does
-- NOT send any notification, and does NOT touch order_status, rider_assignments, or any other
-- user-visible column -- it only resets an internal worker-coordination boolean on orders
-- dispatch no longer has any reason to care about (order_status already left 'searching').
-- Piggybacks on the same already-scheduled 15s cron (redispatch_stalled_searching_orders,
-- 20260808000003) rather than adding a new schedule.

CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()
RETURNS void AS $$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
    v_max_search_duration_sec integer;
    v_order RECORD;
BEGIN
    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_role_key IS NULL THEN
        RAISE WARNING 'redispatch_stalled_searching_orders skipped: vault secret "supabase_service_role_key" is not configured.';
        RETURN;
    END IF;

    SELECT COALESCE(max_search_duration_sec, 900)
    INTO v_max_search_duration_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_max_search_duration_sec := COALESCE(v_max_search_duration_sec, 900);

    FOR v_order IN (
        SELECT o.id
        FROM public.orders o
        WHERE o.order_status = 'searching'
          AND o.order_type NOT IN ('intercity_ride', 'intercity_parcel')
          AND o.created_at >= (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
          AND COALESCE(o.dispatch_worker_running, false) = false
          AND (
              o.dispatch_worker_started_at IS NULL
              OR o.dispatch_worker_started_at < (NOW() - INTERVAL '20 seconds')
          )
    ) LOOP
        BEGIN
            PERFORM net.http_post(
                url := v_supabase_url || '/functions/v1/start-dispatch',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || v_service_role_key,
                    'apikey', v_service_role_key
                ),
                body := jsonb_build_object(
                    'order_id', v_order.id,
                    'is_background', true
                ),
                timeout_milliseconds := 5000
            );
        EXCEPTION WHEN OTHERS THEN
            -- One order's failed re-invocation attempt must never block the rest of this sweep --
            -- it will simply be retried again on the next 15s tick.
            RAISE WARNING 'redispatch_stalled_searching_orders: failed to re-invoke start-dispatch for order %: %', v_order.id, SQLERRM;
        END;
    END LOOP;

    -- Orphaned-lock cleanup (new, see migration header): orders no longer being searched for,
    -- whose worker never reset dispatch_worker_running because its process was killed before
    -- finally() ran. 120s matches start-dispatch's own stale-lock threshold (index.ts
    -- forceAcquire), so this can never touch a lock a legitimately still-finishing worker could
    -- plausibly still hold.
    UPDATE public.orders
    SET dispatch_worker_running = false
    WHERE dispatch_worker_running = true
      AND order_status != 'searching'
      AND dispatch_worker_started_at IS NOT NULL
      AND dispatch_worker_started_at < (NOW() - INTERVAL '120 seconds');
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;
