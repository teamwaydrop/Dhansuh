-- Migration: move the new-order "assign to any already-online nearby rider" scan off the
-- synchronous order-INSERT transaction.
--
-- P2 #1 (WayDrop production-scale audit, P2 fix pass): trigger_assign_new_order_to_nearby_riders
-- (20260808000005_assign_new_order_to_nearby_online_riders.sql) is the one remaining trigger on
-- orders/rider_assignments/riders that still runs its full matching work SYNCHRONOUSLY inside the
-- triggering transaction -- its two siblings (assign_nearby_searching_orders_on_rider_freed,
-- 20260809000001; on_order_status_update's notification dispatch, 20260810000000) were already
-- converted to the same async net.http_post pattern after a proven production incident where this
-- exact shape of inline trigger work caused statement-timeout row-lock contention on the calling
-- UPDATE/INSERT. This migration applies the IDENTICAL, already-twice-proven pattern to the last
-- holdout, for the same reason: this trigger's own cost grows with online-fleet size (it loops
-- every online rider within round_2_radius_km of the new order's pickup point), and it currently
-- extends the lock on the just-inserted orders row for as long as that loop takes.
--
-- SCOPE, DELIBERATELY MINIMAL -- nothing about WHAT gets matched changes, only WHEN/WHERE it runs:
--   - The candidate-selection query (online riders within round_2_radius_km, haversine distance)
--     is copied verbatim into a new function, assign_new_order_to_nearby_online_riders_core(),
--     parameterized by order_id instead of reading the trigger's NEW record directly (the async
--     call can only pass parameters, not a live row reference).
--   - The per-rider eligibility/assignment step is UNCHANGED: still exactly one call to
--     public.assign_nearby_searching_orders_core(...) per candidate rider, same arguments, same
--     function, same business rules (vehicle/weight/service-mode matching, re-offer-with-boost
--     rules, tax-due/COD-limit blocks) -- this migration does not touch that function at all.
--   - The trigger function itself (assign_new_order_to_nearby_online_riders(), same name, same
--     signature, same CREATE TRIGGER binding -- untouched, no DROP/CREATE TRIGGER needed) becomes
--     a thin async enqueue: same two early-return guards it already had (order_status='searching',
--     pickup_lat/lng present -- both redundant with the trigger's own WHEN clause but kept exactly
--     as they were, unchanged), then ONE net.http_post to the new _core function via its
--     PostgREST RPC endpoint, using the exact vault-secret + service-role-bearer pattern already
--     live in production for both sibling fixes. No new queue/architecture -- this is the same
--     mechanism, applied a third time.
--
-- WHY THIS DOESN'T CHANGE MATCHING BEHAVIOR OR CREATE DUPLICATES (verified against the current
-- schema before writing this migration, mirroring the original migration's own safety notes):
--   - assign_nearby_searching_orders_core() already re-validates everything itself from scratch
--     (re-selects currently-'searching' orders, re-checks tax-due/COD-limit) -- it never trusted
--     the caller's snapshot of order/rider state even in the synchronous version, so the small
--     (typically sub-second, per the sibling migrations' own measurements) async gap between the
--     INSERT committing and this enqueued call running changes nothing about correctness, only
--     timing.
--   - rider_assignments has UNIQUE (order_id, rider_id), and assign_nearby_searching_orders_core()
--     already wraps its INSERT in EXCEPTION WHEN unique_violation THEN NULL -- unchanged, still
--     applies. This trigger has always run "in addition to, not instead of" start-dispatch's own
--     independent matching loop (fired fire-and-forget by create-order immediately after insert,
--     unaffected by this migration) -- the two paths racing to assign the same rider first was
--     already a normal, already-safe occurrence before this change.
--   - on_rider_assignment_change() (the assignment push-notification trigger) already only
--     notifies on TG_OP='INSERT' OR a genuine status change away from 'sent' -- unaffected.
--   - Best-effort: if the async enqueue itself fails for any reason, it's logged (RAISE WARNING),
--     never thrown -- exactly as both sibling fixes already do. This trigger was always just a
--     latency optimization layered on top of start-dispatch's own independent matching (per the
--     original migration's own header: "in addition to, not instead of"), never the only path to a
--     match, so a failed enqueue here degrades gracefully to "this rider is found on start-dispatch's
--     own next round" instead of "never found."

-- =====================================================================================
-- 1. New function: the exact same candidate-selection + per-rider matching loop the trigger used
--    to run inline, now parameterized by order_id so it can be invoked out-of-transaction.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders_core(
    p_order_id uuid
)
RETURNS void AS $$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_rider RECORD;
BEGIN
    SELECT id, user_id, order_status, pickup_lat, pickup_lng
    INTO v_order
    FROM public.orders
    WHERE id = p_order_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_order.order_status != 'searching' THEN
        RETURN;
    END IF;

    IF v_order.pickup_lat IS NULL OR v_order.pickup_lng IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(round_2_radius_km, 5.0) INTO v_radius_km
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;
    v_radius_km := COALESCE(v_radius_km, 5.0);

    -- Byte-for-byte identical to the loop this replaces inside
    -- assign_new_order_to_nearby_online_riders() (20260808000005) -- only NEW.* references became
    -- v_order.* after the fresh SELECT above.
    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND r.user_id != v_order.user_id
          AND (
              6371 * acos(
                  LEAST(GREATEST(
                      cos(radians(v_order.pickup_lat)) * cos(radians(r.current_lat))
                          * cos(radians(r.current_lng) - radians(v_order.pickup_lng))
                      + sin(radians(v_order.pickup_lat)) * sin(radians(r.current_lat))
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
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

-- =====================================================================================
-- 2. The trigger function itself: now a thin, fast, best-effort async enqueue -- same shape as
--    assign_nearby_searching_orders_on_rider_freed() (20260809000001) and
--    on_order_status_update() (20260810000000). Same name/signature as before, so the existing
--    CREATE TRIGGER trigger_assign_new_order_to_nearby_riders binding (20260808000005) needs no
--    change at all.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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
$$;
