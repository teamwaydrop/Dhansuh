CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
