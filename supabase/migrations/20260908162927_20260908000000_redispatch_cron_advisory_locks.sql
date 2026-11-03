
-- PHASE 10E — PHASE 2C: redispatch cron self-overlap guard (advisory lock)
-- Additive only: two CREATE OR REPLACE FUNCTION. No cron.schedule, no GRANT change, no new object.
-- Function bodies reproduced byte-for-byte from the live definitions except the leading
-- pg_try_advisory_xact_lock guard. Lock namespace 4735021 (classifier 1 = freed_riders,
-- 2 = stalled_searching_orders); transaction-scoped, auto-released on commit/error/timeout.

CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rider RECORD;
BEGIN
    IF NOT pg_try_advisory_xact_lock(4735021, 1) THEN
        RAISE NOTICE 'redispatch_freed_riders: previous sweep still running -- skipping this tick.';
        RETURN;
    END IF;

    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM public.orders o
              WHERE o.rider_id = r.id
                AND o.updated_at >= NOW() - INTERVAL '5 minutes'
          )
          AND NOT EXISTS (
              SELECT 1 FROM public.orders bo
              WHERE bo.rider_id = r.id
                AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')
          )
    ) LOOP
        BEGIN
            PERFORM public.assign_nearby_searching_orders_core(
                v_rider.id,
                v_rider.user_id,
                v_rider.current_lat,
                v_rider.current_lng,
                v_rider.service_mode
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'redispatch_freed_riders: failed to rematch rider %: %', v_rider.id, SQLERRM;
        END;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()
RETURNS void AS $$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
    v_max_search_duration_sec integer;
    v_order RECORD;
BEGIN
    IF NOT pg_try_advisory_xact_lock(4735021, 2) THEN
        RAISE NOTICE 'redispatch_stalled_searching_orders: previous sweep still running -- skipping this tick.';
        RETURN;
    END IF;

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
            RAISE WARNING 'redispatch_stalled_searching_orders: failed to re-invoke start-dispatch for order %: %', v_order.id, SQLERRM;
        END;
    END LOOP;

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
