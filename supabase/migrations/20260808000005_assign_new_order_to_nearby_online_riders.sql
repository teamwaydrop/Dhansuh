-- Mirrors the existing rider-online instant-assignment trigger onto order creation, so a newly
-- created order finds any already-online nearby rider synchronously, in the same transaction, in
-- addition to (not instead of) the asynchronous start-dispatch edge function. Reuses
-- assign_nearby_searching_orders_core() -- the exact same function already used by
-- trigger_assign_nearby_orders (rider goes online) and
-- trigger_assign_nearby_orders_on_rider_freed (rider finishes a ride) -- as the single source of
-- truth for assignment-creation business rules (vehicle/weight/service-mode matching, re-offer on
-- expired/rejected with a fare boost, etc). start-dispatch is untouched and remains solely
-- responsible for retries and radius escalation (round 2/3, timeout, cron redispatch) when no
-- rider is found by this trigger at insert time.
--
-- ROOT CAUSE this closes: unlike the rider side (riders.account_status -> online has a synchronous
-- AFTER UPDATE trigger), there was no equivalent AFTER INSERT trigger on orders -- a newly created
-- order's only path to a rider was the asynchronous start-dispatch loop (HTTP call + Deno cold
-- start + built-in 2s/15s retry sleeps), even when an eligible rider was sitting right next to the
-- pickup point the entire time. Verified via production data: 20/20 real assignments to a
-- co-located rider (distance 0.01-0.14km, trivially within round 1's 3km) still took 11-895s
-- (median ~40s) to be written, entirely inside start-dispatch's own retry loop, while the
-- rider-side trigger (toggling online) resolved the same match in ~1s with zero retries.
--
-- Safety, verified against the live production schema before writing this migration:
--  - rider_assignments has UNIQUE (order_id, rider_id) (rider_assignments_order_id_rider_id_key),
--    and assign_nearby_searching_orders_core() already wraps its INSERT in
--    EXCEPTION WHEN unique_violation THEN NULL -- a second writer for the same pair is a safe no-op.
--  - start-dispatch's own dispatchRows upsert uses ON CONFLICT (order_id, rider_id) DO UPDATE, and
--    excludes riders with an existing 'sent'/'accepted' row before even building its batch -- it
--    will never re-notify or duplicate a rider this trigger already assigned.
--  - on_rider_assignment_change() (the push-notification trigger) only sends a notification when
--    TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent' -- a later writer
--    re-affirming 'sent' on an already-'sent' row does not re-notify.
--  - prevent_local_ride_assignment_to_busy_rider() (BEFORE INSERT OR UPDATE, applies to every
--    writer of this table) already guards the busy-rider case that
--    assign_nearby_searching_orders_core() itself does not check inline -- unaffected by adding a
--    new caller.

CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_radius_km double precision;
    v_rider RECORD;
BEGIN
    IF NEW.order_status != 'searching' THEN
        RETURN NEW;
    END IF;

    IF NEW.pickup_lat IS NULL OR NEW.pickup_lng IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(round_2_radius_km, 5.0) INTO v_radius_km
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;
    v_radius_km := COALESCE(v_radius_km, 5.0);

    -- Pre-filter candidates by distance so this loop stays bounded by "how many riders are online
    -- within radius" (naturally small) rather than the whole online fleet, before invoking the
    -- same per-rider core function the rider-side triggers already use -- it performs its own,
    -- more detailed per-order eligibility checks (vehicle type, weight, service mode, existing
    -- assignment state, re-offer rules) internally, unchanged.
    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND r.user_id != NEW.user_id
          AND (
              6371 * acos(
                  LEAST(GREATEST(
                      cos(radians(NEW.pickup_lat)) * cos(radians(r.current_lat))
                          * cos(radians(r.current_lng) - radians(NEW.pickup_lng))
                      + sin(radians(NEW.pickup_lat)) * sin(radians(r.current_lat))
                  , -1.0), 1.0)
              )
          ) <= v_radius_km
    ) LOOP
        PERFORM public.assign_nearby_searching_orders_core(
            v_rider.id,
            v_rider.user_id,
            v_rider.current_lat,
            v_rider.current_lng,
            v_rider.service_mode
        );
    END LOOP;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_assign_new_order_to_nearby_riders ON public.orders;

CREATE TRIGGER trigger_assign_new_order_to_nearby_riders
AFTER INSERT ON public.orders
FOR EACH ROW
WHEN (NEW.order_status = 'searching')
EXECUTE FUNCTION public.assign_new_order_to_nearby_online_riders();
