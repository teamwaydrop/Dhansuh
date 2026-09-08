-- =============================================================================
-- BUGFIX (perf slowdown investigation, 2026-09-08, live-monitored test)
--
-- rider_assignments is missing the columns `accepted_at` and `rejected_at`.
-- They were never in the baseline schema (20260529000000) and no later migration
-- ever added them — but the edge functions write them:
--   * supabase/functions/start-dispatch/index.ts:633-634
--       .upsert({ ..., accepted_at: null, rejected_at: null }, ...)
--   * supabase/functions/accept-order/index.ts:432
--       .insert({ ..., accepted_at: nowStr, ... })
--
-- SYMPTOM: every start-dispatch assignment upsert fails with PostgREST
-- PGRST204 ("Could not find the 'accepted_at' column of 'rider_assignments'
-- in the schema cache"), so NO rider_assignments row is created and the
-- assigned rider never receives the realtime INSERT that is the fast dispatch
-- path. Orders then only match via the slower fallback paths (the
-- assign_nearby_searching_orders_core trigger / the redispatch cron), which is
-- the observed 20–40 s delay before a rider is offered / accepts a ride, and
-- the "partner received the ride but the passenger screen still shows Book Now".
-- accept-order's no-pre-existing-assignment insert branch fails the same way.
--
-- FIX: add the two columns. Purely additive, nullable, no default. Neither
-- column is READ anywhere in the codebase (grep-verified) — they are
-- write-only — so this changes nothing except that the writes now succeed.
--
-- REVERSIBLE:
--   ALTER TABLE public.rider_assignments DROP COLUMN accepted_at, DROP COLUMN rejected_at;
-- =============================================================================

ALTER TABLE public.rider_assignments
    ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
    ADD COLUMN IF NOT EXISTS rejected_at timestamptz;

NOTIFY pgrst, 'reload schema';
