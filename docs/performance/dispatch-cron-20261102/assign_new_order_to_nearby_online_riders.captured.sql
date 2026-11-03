CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    IF NEW.order_status != 'searching' THEN
        RETURN NEW;
    END IF;

    IF NEW.pickup_lat IS NULL OR NEW.pickup_lng IS NULL THEN
        RETURN NEW;
    END IF;

    BEGIN
        SELECT decrypted_secret INTO v_service_role_key
        FROM vault.decrypted_secrets
        WHERE name = 'supabase_service_role_key'
        LIMIT 1;

        IF v_service_role_key IS NOT NULL THEN
            PERFORM net.http_post(
                url := v_supabase_url || '/rest/v1/rpc/assign_new_order_to_nearby_online_riders_core',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || v_service_role_key,
                    'apikey', v_service_role_key
                ),
                body := jsonb_build_object(
                    'p_order_id', NEW.id
                ),
                timeout_milliseconds := 5000
            );
        ELSE
            RAISE WARNING 'assign_new_order_to_nearby_online_riders: vault secret "supabase_service_role_key" is not configured -- skipping async nearby-rider match for order %', NEW.id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Never block the order's own creation on the async enqueue itself failing -- start-dispatch
        -- (fired independently by create-order) remains the primary, unaffected matching path either
        -- way; this trigger was always a latency optimization layered on top of it, never the only
        -- route to a match.
        RAISE WARNING 'assign_new_order_to_nearby_online_riders: failed to enqueue async nearby-rider match for order %: %', NEW.id, SQLERRM;
    END;

    RETURN NEW;
END;
$function$
;
