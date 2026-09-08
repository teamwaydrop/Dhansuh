-- Migration: Issue 1 follow-up -- Ride B still not appearing after Rider A completes Ride A, even
-- with the payment_pending fix and redispatch_freed_riders backstop live in production.
--
-- INVESTIGATION (live production forensics on the reporter's own real-device test data, not
-- assumed): traced order ff81a376 (Ride A, local) -> a22a1ef7 (Ride B, local, created while Ride A
-- was still in payment_pending -- correctly rejected by the busy guard, confirmed via one
-- order_assignment_logs row and zero rider_assignments rows, exactly as intended). Ride A completed
-- at 22:00:46. The rider's push-notification history shows ZERO "New Order Request" notifications
-- (the notification on_rider_assignment_change() sends on every genuine new rider_assignments
-- 'sent' row) between 22:00:46 and 22:02:36 -- a ~110 second gap during which
-- redispatch_freed_riders (20s interval) should have ticked ~5 times. The next successful match for
-- this rider (22:02:36) was for a DIFFERENT, intercity_parcel order, proving the rider's own
-- service_mode had already flipped to 'intercity' by then (assign_nearby_searching_orders_core's
-- own service_mode equality check would otherwise have rejected it) -- consistent with the tester
-- switching modes to move on to testing the intercity issues in the same session, which is a
-- legitimate mode change (rider_is_on_active_trip() no longer blocks it once Ride A is completed)
-- and not itself a bug. No other structural defect was found in the deployed trigger/guard/
-- find_nearby_riders chain (all three re-verified live, matching 20260825000000 exactly).
--
-- However, this investigation could not fully rule out a real race in the first 20-40 seconds
-- after a rider is freed, purely from historical data (no per-event audit trail for
-- riders.service_mode changes exists to pin down the exact switch moment). Two changes ship as a
-- result, addressing both the residual uncertainty and a gap already flagged (but deferred as
-- optional) in the prior backstop safety review:
--
-- 1. rider_self_rematch(): a new, narrowly-scoped RPC the rider's OWN client calls the instant it
--    detects its own busy->free transition (RiderOrdersScreen._pollActiveOrderFallback()'s existing
--    wasBusy && !hasActiveOrder check -- no new timer, no new polling loop, purely event-driven off
--    a transition the client already detects). It resolves the CALLING rider's own id/user_id/
--    location/service_mode via auth.uid() and calls the exact same, unmodified
--    assign_nearby_searching_orders_core() synchronously, in the same request -- giving a
--    sub-second guarantee independent of the 20s cron tick or the async trigger's pg_net hop, for
--    the specific rider who just became free. It can only ever act on the caller's own rider
--    profile (auth.uid() bound), so it cannot be used to force-match an arbitrary rider -- the exact
--    same safety property PostgREST already gives every other SECURITY DEFINER RPC in this schema.
--    This is additive: the async trigger and the cron backstop are both untouched and remain the
--    fallback if the client is backgrounded/killed before this fires.
--
-- 2. redispatch_freed_riders(): each rider's PERFORM is now wrapped in its own BEGIN/EXCEPTION WHEN
--    OTHERS, matching the existing pattern already used by redispatch_stalled_searching_orders() --
--    one rider's unexpected failure can no longer abort the rest of that tick's batch. This was
--    explicitly identified as a non-blocking, optional hardening in the prior backstop safety
--    review; promoting it here removes one more possible (if unproven) source of a missed window.
--    No other logic in this function changes -- same candidate query, same blocking set, same
--    5-minute bound.

-- =====================================================================================
-- 1. rider_self_rematch() -- caller-scoped, immediate self-rematch.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.rider_self_rematch()
RETURNS void AS $$
DECLARE
    v_rider RECORD;
BEGIN
    SELECT id, user_id, current_lat, current_lng, service_mode
    INTO v_rider
    FROM public.riders
    WHERE user_id = auth.uid();

    IF NOT FOUND THEN
        RETURN;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        v_rider.id,
        v_rider.user_id,
        v_rider.current_lat,
        v_rider.current_lng,
        v_rider.service_mode
    );
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.rider_self_rematch() TO authenticated;

-- =====================================================================================
-- 2. redispatch_freed_riders() -- per-rider exception isolation added; everything else
--    byte-for-byte identical to the live 20260824000000 definition.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()
RETURNS void AS $$
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
              -- pipeline (includes payment_pending per 20260825000000).
              SELECT 1 FROM public.orders bo
              WHERE bo.rider_id = r.id
                AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
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
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;
