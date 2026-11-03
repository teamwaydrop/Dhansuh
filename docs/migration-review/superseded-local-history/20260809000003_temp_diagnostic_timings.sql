-- TEMPORARY DIAGNOSTIC MIGRATION -- WayDrop Progressive Degradation Investigation (2026-08-08).
--
-- Adds a scratch table for Edge Function round-trip timing instrumentation (start-dispatch,
-- get-live-order-status, update-order-status), added purely to measure the magnitude of a
-- suspected DB-connection/round-trip-queueing bottleneck across a Ride 1 -> Ride 2 -> Ride 3 test
-- session, before any fix is proposed. No existing table, trigger, function, or RLS policy is
-- touched. No application code path reads from this table -- it is write-only from the
-- instrumented edge functions and read-only from the investigator's own ad-hoc queries.
--
-- DELETE THIS MIGRATION'S TABLE (DROP TABLE public.diagnostic_timings;) once the investigation
-- concludes -- it is not meant to be permanent.

CREATE TABLE IF NOT EXISTS public.diagnostic_timings (
    id bigserial PRIMARY KEY,
    fn_name text NOT NULL,
    label text NOT NULL,
    order_id uuid NULL,
    started_at timestamptz NOT NULL,
    duration_ms integer NOT NULL,
    extra jsonb NULL,
    inserted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_timings_started_at ON public.diagnostic_timings (started_at);
CREATE INDEX IF NOT EXISTS idx_diagnostic_timings_order_id ON public.diagnostic_timings (order_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_timings_fn_label ON public.diagnostic_timings (fn_name, label);

-- No RLS needed/enabled: only ever written by the service-role client inside edge functions, and
-- only ever read by direct `supabase db query --linked` (service role / postgres role), never by
-- the app's anon/authenticated PostgREST roles.
ALTER TABLE public.diagnostic_timings ENABLE ROW LEVEL SECURITY;
-- Deliberately zero policies: RLS enabled with no policies means anon/authenticated get nothing,
-- while service_role (used by every edge function and by `supabase db query`) bypasses RLS
-- entirely, exactly as it does for every other table.

-- RLS bypass (rolbypassrls) and standard table GRANTs are separate Postgres privilege systems --
-- a brand-new table created outside the Supabase dashboard's normal table-creation flow has no
-- default GRANT to service_role until one is added explicitly. Without this, every edge function
-- insert into this table fails silently (42501 permission denied, swallowed by diag.ts's
-- best-effort catch) -- confirmed live via a direct PostgREST insert on 2026-08-08.
GRANT SELECT, INSERT ON public.diagnostic_timings TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.diagnostic_timings_id_seq TO service_role;
