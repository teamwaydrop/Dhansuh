-- Migration: reduce execution frequency of the two highest-frequency pg_cron backstop jobs.
--
-- ROOT CAUSE (Ride 1-5 forensic investigation, 2026-08-08): pg_cron's own job-execution log
-- (cron.job_run_details) shows 7 "job startup timeout" failures -- pg_cron's internal error
-- meaning it could not obtain a new Postgres backend connection to even START the job --
-- clustered exactly inside the one severe-contention incident window (Ride 3, 14:21-14:26) and
-- occurring zero times during any healthy window in the same session. This is direct, timestamped
-- proof of intermittent Postgres backend-connection/compute exhaustion, not a slow query (both
-- jobs' own successful runs average well under 1 second; pg_stat_statements/diagnostic_timings
-- data from the same investigation confirms no query executed by either job is inherently
-- expensive at this project's current data volume).
--
-- P0 FIX (approved scope: frequency only, no logic change): halve how often these two jobs
-- attempt to acquire a connection, reducing their contribution to peak simultaneous connection
-- demand. This is a pure schedule change via cron.alter_job() -- neither job's SQL command, its
-- underlying function body, nor its WHERE-clause scoping is touched in any way. Both jobs remain
-- exactly as safe/correct as before; only their worst-case recovery latency for the abnormal
-- conditions they backstop increases modestly (see below), which is an accepted, deliberate
-- trade confirmed against neither job being a primary/user-facing path:
--
--   redispatch-stalled-searching-orders: 15s -> 30s. This is a BACKSTOP, not the primary dispatch
--   path (a new order's own start-dispatch invocation fires immediately and directly from
--   create-order, independent of this cron). It only re-invokes start-dispatch for a 'searching'
--   order whose own dispatch worker died without one already running. Worst-case added delay for
--   that already-abnormal case: 15 seconds. Its orphaned dispatch_worker_running lock cleanup
--   (WHERE ... < NOW() - INTERVAL '120 seconds') is unaffected by this schedule change since its
--   own 120s threshold is far larger than either the old or new cron interval.
--
--   expire-stale-searching-orders: 1min -> 2min. This expires a 'searching' order only after it
--   has already exceeded its own configured max_search_duration_sec (default 900s = 15 minutes)
--   -- a correctness safety net for an already multi-minute-scale condition. Worst-case added
--   delay before expiry is caught: 60 seconds, negligible relative to the 900s threshold it's
--   already waiting on. Its independent rider_assignments expiry sweep (`expires_at < NOW()`) is
--   likewise unaffected by this schedule change.
--
-- Verified before writing this migration: neither job has ever overlapped with its own previous
-- run (0 self-overlapping runs out of 708/180 total runs checked, confirming pg_cron does not
-- launch a new run of the same job while a prior one is still executing) -- this change cannot
-- introduce a new self-overlap failure mode that didn't already exist.
--
-- Explicitly NOT touched: dispatch decision logic, find_nearby_riders, pricing, OTP correctness,
-- the already-deployed async notification trigger, any other cron job, RLS, or any business rule.

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'redispatch-stalled-searching-orders'),
  schedule => '30 seconds'
);

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'expire-stale-searching-orders'),
  schedule => '*/2 * * * *'
);
