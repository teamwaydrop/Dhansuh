-- =============================================================================
-- BUG FIX: redispatch_freed_riders()'s busy-status check was missing 'rider_at_drop',
-- inconsistent with every other busy-order-status list in this pipeline:
--   - loadActiveOrder() (rider_home_tab.dart):
--       ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending']
--   - find_nearby_riders() -> rider_is_on_active_trip()
--   - this function's own comment ("identical blocking set used everywhere else in this pipeline")
--
-- Root cause of "new pending order (Ride B) never surfaced to a partner after they finished their
-- current ride (Ride A)": this cron (runs every 20s via pg_cron job
-- "redispatch-freed-riders") is what re-offers a still-searching order to a rider once they
-- actually become free. With 'rider_at_drop' missing from its own busy-check, a rider genuinely
-- still finishing a delivery (arrived at drop, generating/awaiting OTP confirmation -- not done
-- yet) could be treated as "free" by this specific function while every other part of the system
-- correctly still considered them busy. This function fixes only that one gap; no other logic in
-- redispatch_freed_riders() or assign_nearby_searching_orders_core() changes.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rider RECORD;
BEGIN
    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND EXISTS (
              -- had an order touched recently -- bounds the scan to "just finished something",
              -- not the full online fleet.
              SELECT 1 FROM public.orders o
              WHERE o.rider_id = r.id
                AND o.updated_at >= NOW() - INTERVAL '5 minutes'
          )
          AND NOT EXISTS (
              -- busy-rider protection: identical blocking set used everywhere else in this
              -- pipeline (loadActiveOrder()/find_nearby_riders() -- includes rider_at_drop,
              -- payment_pending per 20260825000000).
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
            -- One rider's unexpected failure must never block the rest of this sweep -- it will
            -- simply be retried again on the next 20s tick.
            RAISE WARNING 'redispatch_freed_riders: failed to rematch rider %: %', v_rider.id, SQLERRM;
        END;
    END LOOP;
END;
$function$;
