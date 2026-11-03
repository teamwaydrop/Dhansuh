-- OPERATOR ONLY, AFTER final GO + verified cutoff for new v60 admissions.
-- psql -v pause_cutoff_utc="<confirmed ISO-8601 UTC cutoff>" -f this-file.sql
-- Use the existing approved secure connection; do not paste credentials.
-- Read-only counters. Does not stop sessions, lock tables or alter data.
BEGIN READ ONLY;
SET LOCAL statement_timeout='3s';
WITH cutoff AS (SELECT :'pause_cutoff_utc'::timestamptz t)
SELECT statement_timestamp() observed_at,
  (SELECT count(*) FROM pg_stat_activity,cutoff
   WHERE datname=current_database() AND pid<>pg_backend_pid()
     AND xact_start IS NOT NULL AND xact_start<=cutoff.t) older_transactions,
  (SELECT count(*) FROM pg_prepared_xacts,cutoff
   WHERE database=current_database() AND prepared<=cutoff.t) older_prepared_transactions,
  (SELECT count(*) FROM pg_locks
   WHERE relation IN ('public.orders'::regclass,'public.rider_assignments'::regclass,
                      'public.order_assignment_logs'::regclass)
     AND mode IN ('RowExclusiveLock','ShareRowExclusiveLock','ExclusiveLock','AccessExclusiveLock')) order_write_locks;
COMMIT;
