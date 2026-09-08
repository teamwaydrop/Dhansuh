-- Migration: remove the temporary diagnostic_timings scratch table and its associated policy.
--
-- P0 FIX #1 (WayDrop Progressive Degradation Investigation, follow-up): the investigation that
-- introduced public.diagnostic_timings (20260809000003_temp_diagnostic_timings.sql) and its
-- client-insert policy (20260811000000_client_diagnostic_timings_rls.sql) has concluded. Both
-- migrations' own headers explicitly said to drop this table once that happened -- it was never
-- meant to be permanent.
--
-- More importantly, the instrumentation that wrote to this table (`timed()`/`recordTiming()` in
-- supabase/functions/_shared/diag.ts, and ClientRequestDiagnostics on the Flutter client) was found
-- to be AWAITED on the caller's critical path -- adding a real extra Postgres round trip to nearly
-- every call in start-dispatch, get-live-order-status, and update-order-status (the exact hot paths
-- implicated in the progressive-slowdown reports). All of that instrumentation code has been
-- deleted in this same change; this migration removes the table it wrote to.
--
-- Forward-only migration per project convention: the original two migrations are left in place
-- unedited (they already ran), this only drops what they created.

DROP POLICY IF EXISTS diagnostic_timings_client_insert ON public.diagnostic_timings;

DROP TABLE IF EXISTS public.diagnostic_timings;
