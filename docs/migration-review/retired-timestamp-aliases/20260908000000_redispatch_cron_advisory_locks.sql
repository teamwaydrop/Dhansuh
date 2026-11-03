-- =============================================================================
-- PHASE 10E — PHASE 2C: redispatch cron self-overlap guard (advisory lock)
-- Date: 2026-09-08
--
-- EVIDENCE (Phase 10B Supabase performance diagnostics):
--   * redispatch_freed_riders() -- one observed execution ~10.18s, pg_cron schedule = every 20s.
--   * redispatch_stalled_searching_orders() -- pg_cron schedule = every 15s.
--   * "potential overlap exists" between consecutive cron ticks; Postgres showed significant
--     lock/contention behaviour and 58s statement timeouts on the dispatch/settlement hot path.
--
-- ROOT CAUSE this migration addresses:
--   pg_cron does NOT serialize a job against its own still-running previous invocation -- if a
--   redispatch sweep is still executing when the next scheduled tick fires, pg_cron starts a
--   SECOND concurrent execution of the SAME function. Both sweeps then iterate the SAME candidate
--   set (freed riders / stalled searching orders) and perform the SAME work
--   (assign_nearby_searching_orders_core per rider; start-dispatch re-invocation per order). This
--   is pure duplicate work + extra row-lock traffic on riders / orders / rider_assignments /
--   order_assignment_logs -- it never produces an additional match (the core matcher's own
--   guards -- unique (order_id, rider_id) on rider_assignments, the fare-gate re-checks, the
--   order_status='searching' filter -- make the second concurrent attempt a no-op), it only adds
--   contention to a path the diagnostics already show as contended.
--
-- FIX (scope item B -- advisory-lock protection against concurrent execution of the SAME cron
-- operation, nothing else):
--   Each function takes a TRANSACTION-SCOPED advisory lock as its very first action. pg_cron runs
--   every invocation in its own transaction, so pg_try_advisory_xact_lock is released
--   automatically the instant that transaction ends -- commit, error, OR statement timeout. It
--   can never leak a lock, and it can never block anything outside these two functions.
--
--   If the lock is already held (the previous tick of the SAME job is still running), the new
--   invocation RETURNs immediately without doing any work. Nothing is lost: the still-running
--   sweep is already covering the same candidate set, and the next scheduled tick retries
--   whatever was still outstanding. This is exactly the semantics of "a concurrent invocation
--   exits safely/no-ops rather than doing duplicate work".
--
-- LOCK KEYS (stable, documented, never reused elsewhere -- `pg_advisory` was previously entirely
-- unused in this schema, per the Phase 14 audit note in
-- 20260903000000_reward_activation_single_use_pass.sql):
--   pg_try_advisory_xact_lock(4735021, 1)  => redispatch_freed_riders()
--   pg_try_advisory_xact_lock(4735021, 2)  => redispatch_stalled_searching_orders()
--   4735021 = WayDrop dispatch-cron advisory namespace. The two operations get DIFFERENT
--   classifier ints (1 vs 2) so they never block each other -- they are independent operations
--   that happen to touch overlapping tables; only a function-vs-itself overlap is prevented.
--
-- EXPLICITLY UNCHANGED (reproduced byte-for-byte from the current live definitions):
--   * redispatch_freed_riders()               -- base: 20260901000017 (rider_at_drop in the
--                                                busy set + per-rider BEGIN/EXCEPTION isolation).
--   * redispatch_stalled_searching_orders()   -- base: 20260809000000 (stalled-order re-invoke
--                                                loop + orphaned dispatch_worker_running cleanup).
--   Every candidate query, every busy-status list, the 5-minute bounded scan, the
--   max_search_duration window, the vault secret lookup, the net.http_post call shape, the
--   per-iteration EXCEPTION handling, the orphaned-lock cleanup UPDATE, the cron schedules
--   ('20 seconds' / '15 seconds'), and both functions' grants/owner/SECURITY DEFINER/search_path
--   are all identical. No business rule, no matching rule, no dispatch behaviour, no schema, no
--   cron interval is touched.
--
-- ADDITIVE ONLY: two CREATE OR REPLACE FUNCTION statements. No cron.schedule call, no GRANT
-- change, no new object.
-- =============================================================================

-- =============================================================================
-- redispatch_freed_riders()  (base: 20260901000017_redispatch_freed_riders_include_rider_at_drop)
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
    -- Phase 10E 2C: self-overlap guard. If the previous 20s tick of THIS cron job is still
    -- running, skip this one entirely rather than run a second concurrent sweep over the same
    -- freed-rider set (pure duplicate work + lock contention; never an extra match). Transaction-
    -- scoped: released automatically when this invocation's transaction ends. See migration
    -- header for the full reasoning and the lock-key registry.
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

-- =============================================================================
-- redispatch_stalled_searching_orders()  (base: 20260809000000_clear_orphaned_dispatch_worker_locks)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders()
RETURNS void AS $$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
    v_max_search_duration_sec integer;
    v_order RECORD;
BEGIN
    -- Phase 10E 2C: self-overlap guard. If the previous 15s tick of THIS cron job is still
    -- running, skip this one entirely rather than re-enqueue start-dispatch for the same stalled
    -- orders and re-run the orphaned-lock cleanup concurrently. Transaction-scoped: released
    -- automatically when this invocation's transaction ends. See migration header.
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
            -- One order's failed re-invocation attempt must never block the rest of this sweep --
            -- it will simply be retried again on the next 15s tick.
            RAISE WARNING 'redispatch_stalled_searching_orders: failed to re-invoke start-dispatch for order %: %', v_order.id, SQLERRM;
        END;
    END LOOP;

    -- Orphaned-lock cleanup (new, see migration header): orders no longer being searched for,
    -- whose worker never reset dispatch_worker_running because its process was killed before
    -- finally() ran. 120s matches start-dispatch's own stale-lock threshold (index.ts
    -- forceAcquire), so this can never touch a lock a legitimately still-finishing worker could
    -- plausibly still hold.
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
