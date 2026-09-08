-- Migration: DB-authoritative auto-expiry for orders stuck in 'searching' past their configured
-- search lifetime, scheduled via pg_cron. No passenger action required.
-- Date: 2026-08-02
--
-- ROOT CAUSE: start-dispatch's own active dispatch loop (supabase/functions/start-dispatch/index.ts)
-- already stops trying once an order's search age exceeds `dispatch_config.max_search_duration_sec`
-- -- but historically only stopped the LOOP, never changed `order_status` (see the companion change
-- in start-dispatch/index.ts landing alongside this migration, which now calls this same function at
-- that exact give-up point). Nothing else in the schema ever expired a `'searching'` order: grepping
-- every migration for `cron.schedule` found exactly 3 jobs (stale travel plans, daily wallet audit,
-- intercity negotiation/travel-plan expiry) and zero touching `orders` or `rider_assignments`. A
-- local ride/parcel order nobody accepted could therefore sit in `order_status = 'searching'`
-- indefinitely -- remaining a live candidate for
-- assign_nearby_searching_orders_to_rider() (bounded to the search window by the companion migration
-- 20260806000002) for as long as it existed, and permanently inflating admin/activity views with
-- orders that will never resolve on their own.
--
-- FIX: a single idempotent, SET-based (not row-by-row RPC-call) function that (a) bulk-expires any
-- order past its search window straight to the pre-existing, previously-unused `'expired'` value of
-- `order_status_enum` (20260529000000_baseline_foundational_schema.sql:111-123 -- already in the
-- schema, never written by any code path until now), with a matching `order_status_history` row for
-- audit parity with every other status-changing code path in this codebase, and (b) independently
-- sweeps any `rider_assignments` row still `'sent'` past its own `expires_at`, as a safety net for
-- assignments a dispatch worker or the client's own local timer never got to close out. Both halves
-- are bounded by the partial indexes added in 20260806000003_add_dispatch_staleness_partial_indexes.sql,
-- so their cost tracks CURRENT search volume, not total historical order/assignment count.
--
-- Passengers are notified automatically: `on_order_status_update()`
-- (AFTER UPDATE OF order_status ON orders FOR EACH ROW) already fires per-row on this bulk UPDATE
-- exactly as it does for any other status change, so this function must NOT also call
-- send_push_notification_fnc itself -- doing so would double-notify. A dedicated, properly-worded
-- 'expired' branch for that existing trigger is added in
-- 20260806000005_add_expired_order_notification_copy.sql so the passenger sees a clear message
-- instead of that trigger's generic fallback string.
--
-- SCOPE: intercity_ride/intercity_parcel orders are deliberately excluded from part (a), matching
-- start-dispatch's own existing exclusion for these order types (index.ts:137-149) -- they are
-- matched via the separate travel-plan/intercity_requests negotiation flow, which already has its
-- own independent expiry job (expire_stale_intercity_requests(),
-- 20260717000008_intercity_expiry_scheduling_and_notifications.sql) with its own timing rules. This
-- function must not reinterpret or shorten that flow's window.
CREATE OR REPLACE FUNCTION public.expire_stale_searching_orders()
RETURNS void AS $$
DECLARE
    v_max_search_duration_sec integer;
    v_order RECORD;
    v_expired_count integer := 0;
BEGIN
    SELECT COALESCE(max_search_duration_sec, 900)
    INTO v_max_search_duration_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_max_search_duration_sec := COALESCE(v_max_search_duration_sec, 900);

    FOR v_order IN
        UPDATE public.orders
        SET order_status = 'expired',
            updated_at = NOW()
        WHERE order_status = 'searching'
          AND order_type NOT IN ('intercity_ride', 'intercity_parcel')
          AND created_at < (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
        RETURNING id
    LOOP
        v_expired_count := v_expired_count + 1;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        VALUES (
            v_order.id,
            'searching',
            'expired',
            'system',
            'Auto-expired: no rider accepted within the configured search window.'
        );

        -- Close out any outstanding 'sent' assignment for this order -- it is now moot, and must
        -- never be resettable back to 'sent' by assign_nearby_searching_orders_to_rider() (which is
        -- itself now guarded against this by the companion migration's created_at bound, but closing
        -- it here too keeps rider_assignments/order_assignment_logs consistent with the same
        -- cleanup update-order-status's 'cancelled' branch already performs for every other
        -- terminal-order-state transition).
        UPDATE public.rider_assignments
        SET assignment_status = 'expired',
            responded_at = NOW(),
            updated_at = NOW(),
            response_type = 'ignored'
        WHERE order_id = v_order.id
          AND assignment_status = 'sent';

        UPDATE public.order_assignment_logs
        SET assignment_status = 'expired',
            responded_at = NOW()
        WHERE order_id = v_order.id
          AND assignment_status = 'sent';
    END LOOP;

    IF v_expired_count > 0 THEN
        RAISE LOG '[expire_stale_searching_orders] Expired % order(s) past their % second search window.', v_expired_count, v_max_search_duration_sec;
    END IF;

    -- Independent safety net: expire any 'sent' rider_assignments whose OWN expires_at has passed,
    -- regardless of their order's status (covers assignments a dispatch worker or the client's local
    -- timer never got to close out, e.g. app backgrounded/killed mid-round). Bounded by
    -- idx_rider_assignments_sent_expires_at.
    UPDATE public.rider_assignments
    SET assignment_status = 'expired',
        responded_at = NOW(),
        updated_at = NOW(),
        response_type = 'ignored'
    WHERE assignment_status = 'sent'
      AND expires_at < NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- Internal maintenance function only -- invoked by pg_cron (runs as the job owner, not via
-- PostgREST) and directly by start-dispatch using the service-role key. Never intended to be
-- reachable by an authenticated client (it mutates orders/rider_assignments platform-wide with no
-- caller-scoping), so unlike find_nearby_riders()/is_rider_blocked_by_tax_due() this is
-- deliberately NOT granted to `authenticated`.
GRANT EXECUTE ON FUNCTION public.expire_stale_searching_orders() TO service_role;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'expire-stale-searching-orders',
            '*/1 * * * *', -- every minute -- cheap thanks to the partial indexes, and bounds how
                            -- long an abandoned order can remain a dispatch candidate even if
                            -- start-dispatch's own give-up call (see start-dispatch/index.ts) is
                            -- somehow never reached (e.g. a crashed/never-chained worker).
            'SELECT public.expire_stale_searching_orders();'
        );
    END IF;
END $$;
