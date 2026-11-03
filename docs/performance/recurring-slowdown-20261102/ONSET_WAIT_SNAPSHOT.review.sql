-- REVIEW ONLY. Not automatically executed; no schema/configuration changes.
-- One snapshot cannot reconstruct history. A separately approved short collector
-- can issue this once/second at the NEXT onset, outside a long-lived transaction.
-- Requires existing authority to view other sessions; grants are NOT changed here.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '1500ms';
SELECT clock_timestamp() AS sampled_at, a.pid, a.backend_start,
       a.usename AS database_role,
       CASE WHEN a.application_name IN ('postgrest','postgres_exporter','pg_cron scheduler',
                'realtime_rls','realtime_subscription_manager','realtime_connect')
            THEN a.application_name ELSE 'other' END AS application,
       a.backend_type, a.state, a.query_start, a.xact_start,
       a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS blocking_pids,
       a.query_id, md5(a.query) AS query_fingerprint
FROM pg_stat_activity a
WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
ORDER BY a.pid;
COMMIT;
-- Never collect raw query bodies, JWTs, push tokens or message contents here.
-- Correlate with native host CPU/steal, memory/swap and device latency series.
-- A blank wait_event alone does NOT prove CPU saturation.
