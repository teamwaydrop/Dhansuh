-- Migration: Partial indexes backing the dispatch-staleness bound added in
-- 20260806000002_bound_dispatch_trigger_ttl_and_online_transition_only.sql and the auto-expiry job
-- added in 20260806000004_add_expire_stale_searching_orders_and_schedule.sql.
-- Date: 2026-08-02
--
-- Both of those rely on two predicates that must stay cheap as the platform scales to tens or
-- hundreds of thousands of users: "orders currently order_status = 'searching'" and
-- "rider_assignments currently assignment_status = 'sent'". A full table (or even a full
-- non-partial-indexed) scan of either table grows with TOTAL historical order/assignment volume --
-- exactly the growth pattern that must not happen for this fix to actually be bounded at scale.
-- A partial index whose predicate matches the query's own WHERE clause instead only ever contains
-- CURRENTLY-searching orders / CURRENTLY-sent assignments -- a small, roughly constant-sized set
-- regardless of how many orders or assignments have ever existed, so both the trigger's per-heartbeat
-- (now per-online-transition) candidate scan and the cron sweep's bulk UPDATE stay cheap at 1,000,
-- 10,000, or 100,000 users; only the platform's CONCURRENT search volume affects their cost, not its
-- historical total.
CREATE INDEX IF NOT EXISTS idx_orders_searching_created_at
    ON public.orders (created_at)
    WHERE order_status = 'searching';

CREATE INDEX IF NOT EXISTS idx_rider_assignments_sent_expires_at
    ON public.rider_assignments (expires_at)
    WHERE assignment_status = 'sent';
