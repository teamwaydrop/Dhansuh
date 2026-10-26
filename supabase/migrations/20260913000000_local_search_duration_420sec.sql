-- =============================================================================
-- CONFIGURATION CHANGE -- local order search/expiry window 900s -> 420s
--
-- Scope: local_ride + local_parcel ONLY.
--
-- Changes the single active dispatch_config row (config_code = 'DEFAULT_V1')
-- so that max_search_duration_sec goes from 900 (15 min) to 420 (7 min).
--
-- WHY THIS IS THE RIGHT (AND ONLY) ROW TO CHANGE:
--   * public.expire_stale_searching_orders() (20260806000004) reads
--     dispatch_config.max_search_duration_sec (COALESCE default 900) and applies
--     it ONLY to orders WHERE order_type NOT IN ('intercity_ride','intercity_parcel').
--     Intercity orders are explicitly excluded from this config's effect.
--   * supabase/functions/start-dispatch/index.ts reads the same column (via
--     _shared/dispatch_config_cache.ts, 30s in-memory TTL, no redeploy needed for
--     this to take effect) to bound its active nearby-rider dispatch loop -- and
--     that function returns immediately for intercity_ride/intercity_parcel
--     orders ("Skipping dispatch loop"), before ever reaching the config-driven
--     loop. So this column has zero effect on intercity behavior today.
--   * public.dispatch_config currently has exactly one row (config_code =
--     'DEFAULT_V1', is_active = true) -- verified before writing this migration.
--
-- Companion change (same deploy, not a migration): supabase/functions/create-order
-- /index.ts's `searchExpiryMinutes` default (local_ride, was 15) and the
-- local_parcel branch (was 20) are both changed to 7 minutes, so the
-- informational orders.search_expires_at value this Edge Function writes at
-- order-creation time never implies a longer window than the DB-authoritative
-- expiry above actually allows. The intercity_ride (30) / intercity_parcel (60)
-- branches in that same function are untouched -- and are themselves only a
-- fallback: for intercity orders with a travel_date, search_expires_at is
-- overwritten with travel_date regardless, per existing (unmodified) logic.
--
-- NOT TOUCHED: expire_stale_intercity_requests(), any intercity dispatch/match
-- function, redispatch/backstop cron logic, RLS, indexes, triggers, other
-- dispatch_config columns (round radii/batch sizes/timeouts/cooldowns).
--
-- IDEMPOTENT: re-running this UPDATE is a no-op once the value is already 420.
-- =============================================================================

UPDATE public.dispatch_config
SET max_search_duration_sec = 420,
    updated_at = now()
WHERE config_code = 'DEFAULT_V1'
  AND is_active = true
  AND max_search_duration_sec IS DISTINCT FROM 420;

-- =============================================================================
-- ROLLBACK (manual):
--   UPDATE public.dispatch_config
--   SET max_search_duration_sec = 900, updated_at = now()
--   WHERE config_code = 'DEFAULT_V1' AND is_active = true;
-- (Also revert the two searchExpiryMinutes literals in create-order/index.ts to
--  15 and 20 and redeploy, if the Edge Function change is rolled back too.)
-- =============================================================================
