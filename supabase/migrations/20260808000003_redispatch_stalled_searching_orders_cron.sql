-- Migration: server-side backstop guaranteeing a "searching" local order whose dispatch worker
-- has silently died still gets re-matched, without needing a rider to toggle offline->online.
-- Date: 2026-08-08
--
-- ROOT CAUSE (proven via live database evidence during this investigation, not assumed):
--   - A brand-new order's ONLY delivery mechanism to an already-online, idle rider is
--     start-dispatch's own self-re-invoking loop (supabase/functions/start-dispatch/index.ts):
--     create-order fires it fire-and-forget (EdgeRuntime.waitUntil, never awaited), and the loop
--     keeps itself alive by re-fetching its own URL (also fire-and-forget) roughly every 85-100s
--     for up to dispatch_config.max_search_duration_sec. Nothing awaits or verifies that
--     self-re-invocation. If it fails for ANY reason (a transient network blip, a failed status
--     re-check query inside the loop's own tail -- e.g. the `checkOrder` query at the "safe
--     timeout reached" branch, whose failure silently falls through to the loop simply not
--     chaining), the order is abandoned mid-search: order_status stays 'searching',
--     dispatch_worker_running is left false, and NOTHING else in the system ever retries it.
--   - Confirmed live: order c11ba73e-12ac-44c1-82a3-250691387f0e (WDRHUHVJE) has
--     dispatch_worker_started_at set within 1s of created_at (the worker DID start) but zero
--     rows in rider_assignments and zero rows in order_assignment_logs for its entire life --
--     while the same rider was successfully matched to orders immediately before and after it at
--     the identical pickup coordinates. This is not a "no supply" case; it's a dead chain.
--   - By contrast, the OFFLINE -> ONLINE path (trigger_assign_nearby_orders on public.riders,
--     20260806000002) is a synchronous, transactional Postgres trigger fired directly by the
--     UPDATE that flips account_status -- it cannot silently fail to run, which is exactly why
--     toggling a rider offline then online "immediately" surfaces an order that never arrived
--     through the normal path. Likewise trigger_assign_nearby_orders_on_rider_freed
--     (20260808000000) only re-offers orders that are ALREADY 'searching' at the instant a ride
--     completes -- it does nothing for an order created afterward, so "stay online, next ride
--     never arrives" (bug report Case 2) collapses into the identical gap as Case 1 (new order to
--     an already-online idle rider): both depend entirely on the same unsupervised HTTP chain.
--
-- FIX: a pg_cron job, in the same established pattern as expire-stale-searching-orders
-- (20260806000004), that runs every 15 seconds and re-invokes start-dispatch (via net.http_post,
-- the same vault-sourced-service-role-key pattern already used by
-- deliver_push_notification_http_fnc, 20260718000000) for any order that looks abandoned: still
-- 'searching', still within its configured search lifetime, and dispatch_worker_running has been
-- false for longer than a legitimate worker hand-off gap ever takes (20s -- a live worker holds
-- dispatch_worker_running=true continuously for its entire ~100s run; the false window between
-- one chain segment ending and the next starting is normally sub-second). This never touches a
-- currently-running worker (dispatch_worker_running=true is left completely alone) and never
-- duplicates start-dispatch's own matching/round/radius logic -- it only guarantees the HTTP
-- invocation that starts that logic actually keeps happening, self-healing on the very next tick
-- if this invocation attempt itself also fails, instead of the order being abandoned forever.
-- Scope matches create-order's own dispatch routing exactly: intercity_ride/intercity_parcel are
-- excluded (they go through match-intercity-riders, a separate pipeline start-dispatch itself
-- already skips).

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
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

SELECT cron.schedule(
    'redispatch-stalled-searching-orders',
    '15 seconds',
    $$SELECT public.redispatch_stalled_searching_orders();$$
);
