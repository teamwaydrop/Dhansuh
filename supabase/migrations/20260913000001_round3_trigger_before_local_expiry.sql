-- =============================================================================
-- CONFIGURATION CHANGE -- Round 3 dispatch trigger 600s -> 360s
--
-- Follow-up to 20260913000000_local_search_duration_420sec.sql, which lowered
-- the local (local_ride/local_parcel) search/expiry window from 900s to 420s.
-- That left round_3_trigger_after_sec (600s) UNREACHABLE: the active dispatch
-- loop's own expiry check (searchAgeSeconds*1000 > max_search_duration_sec*1000)
-- now stops the loop and expires the order at 420s, before search age could
-- ever reach 600s -- Round 3 (10km radius / batch 12) could never fire.
--
-- Scope: round_3_trigger_after_sec ONLY. round_2_trigger_after_sec (300s)
-- stays exactly as-is, per explicit instruction.
--
-- ONLY CONSUMER (verified by inspection): supabase/functions/start-dispatch
-- /index.ts, lines ~409-417:
--   const round3TriggerAfterSec = Number(config.round_3_trigger_after_sec);
--   if (config.allow_round_3 && searchAgeSeconds >= round3TriggerAfterSec) { ...push round 3... }
-- Read via the same 30s-TTL dispatch_config cache as max_search_duration_sec
-- (_shared/dispatch_config_cache.ts) -- no redeploy needed for this value to
-- take effect. Nothing else in the codebase reads round_3_trigger_after_sec
-- (grepped supabase/functions, supabase/migrations, lib/, schema.sql).
--
-- ORDERING WITHIN start-dispatch's loop confirmed safe: the overall-expiry
-- check (searchAgeSeconds*1000 > maxSearchDurationMs) runs BEFORE the
-- round-building block (Round 1/2/3) on every iteration -- so a searching
-- order is still eligible to be matched, and Round 3 still gets built and
-- attempted, for every iteration where 360 <= searchAgeSeconds <= 420, i.e. a
-- genuine ~60s window right up to expiry. The loop self-chains (fire-and-
-- forget re-invocation of start-dispatch when its own ~85s per-invocation
-- safety cap is hit) as long as order_status stays 'searching', so search age
-- keeps advancing across chained invocations regardless of how many
-- invocations it takes to reach 360s/420s -- this is unaffected by this change.
--
-- NEW TIMELINE (local_ride / local_parcel only):
--   Round 1: search age  0s   (round_1_radius_km=3,  batch=5)   -- unchanged
--   Round 2: search age 300s  (round_2_radius_km=5,  batch=8)   -- unchanged
--   Round 3: search age 360s  (round_3_radius_km=10, batch=12)  -- 600 -> 360
--   Expiry:  search age 420s                                    -- unchanged (20260913000000)
--   => Round 3 now has the final ~60s of the search window before expiry.
--
-- NOT TOUCHED: max_search_duration_sec (420, unchanged), round_2_trigger_after_sec
-- (300, unchanged), round_2_trigger_if_no_riders_sec, round radii/batch sizes,
-- allow_round_3, any other dispatch_config column, expire_stale_searching_orders(),
-- expire_stale_intercity_requests(), any intercity dispatch/match function, RLS,
-- indexes, triggers, tax/GST, police disclosure, Flutter/mobile code.
--
-- IDEMPOTENT: re-running this UPDATE is a no-op once the value is already 360.
-- =============================================================================

UPDATE public.dispatch_config
SET round_3_trigger_after_sec = 360,
    updated_at = now()
WHERE config_code = 'DEFAULT_V1'
  AND is_active = true
  AND round_3_trigger_after_sec IS DISTINCT FROM 360;

-- =============================================================================
-- ROLLBACK (manual):
--   UPDATE public.dispatch_config
--   SET round_3_trigger_after_sec = 600, updated_at = now()
--   WHERE config_code = 'DEFAULT_V1' AND is_active = true;
-- =============================================================================
