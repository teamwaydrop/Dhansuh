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
$function$
;
