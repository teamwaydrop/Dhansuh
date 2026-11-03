-- REVIEW ONLY: prepared, not executed. No policies/configuration are changed.
-- At the next latency rise, use an existing authorized collector for at most
-- 120 seconds, one snapshot every 5 seconds. Stop on the first sampling timeout;
-- do not repeatedly enqueue samples against a stalled database.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '1000ms';
SELECT clock_timestamp() AS sampled_at, a.pid, a.backend_start,
       a.usename AS database_role,
       CASE WHEN a.application_name IN ('Supabase Storage API', 'postgrest',
         'postgres_exporter', 'pg_cron scheduler', 'realtime_rls',
         'realtime_subscription_manager', 'realtime_connect')
         THEN a.application_name ELSE 'other' END AS application,
       a.backend_type, a.state, a.query_start, a.xact_start,
       a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS blocking_pids,
       a.query_id, md5(a.query) AS query_fingerprint
FROM pg_stat_activity a
WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
ORDER BY a.pid;
SELECT clock_timestamp() AS sampled_at, datname, numbackends, deadlocks,
       temp_files, temp_bytes, blks_read, blks_hit
FROM pg_stat_database WHERE datname = current_database();
COMMIT;
-- No raw SQL, arguments, user identifiers, messages, URLs or tokens captured.
-- Pair with host CPU modes/steal, MemAvailable, swap-in/out rate, major faults,
-- system/data device latency, queue/IOPS and baseline/burst budget at <=5 sec.
-- Request the Storage service's own admission/pool and metadata-transaction spans
-- by request_id, including backend PID/query_id, from Supabase support.
-- Neither this snapshot nor a blank wait_event alone proves CPU saturation.
