-- =============================================================================
-- PERF (slowdown-after-a-few-rides investigation, 2026-09-08) — Phase 1, item 2
--
-- Reduce the frequency of the two redispatch backstop cron sweeps.
--   redispatch-stalled-searching-orders :  every 30 s  ->  every 1 min ('*/1 * * * *')
--   redispatch-freed-riders             :  every 20 s  ->  every 45 s
--
-- (pg_cron only accepts '[1-59] seconds' for sub-minute intervals, so the
--  stalled-orders job uses standard cron 'every minute' rather than '60 seconds'.)
--
-- WHY:
--   * Per pg_stat_statements these two functions are the dominant steady-state
--     background DB cost (redispatch_stalled ~1.86M ms / 109k calls;
--     redispatch_freed ~1.10M ms / 120k calls).
--   * On every tick they re-enqueue start-dispatch for every still-'searching'
--     order and re-scan every rider whose order was touched in the last 5 min —
--     during testing this compounds into a constant load spike that starves the
--     realtime WAL reader (root cause of the reported UI lag).
--   * They are only the BACKSTOP for the stalled case. The normal path is
--     unaffected: a rider is offered a new order within seconds by
--     start-dispatch and the AFTER INSERT / rider-freed triggers. A 45–60 s
--     retry on the rare stalled order is still far inside the passenger's
--     configured search window (max_search_duration_sec, default 900 s).
--   * Paired with 20260908000000 (advisory-lock self-overlap guard), a sweep can
--     neither overlap itself nor run more often than needed.
--
-- REVERSIBLE: re-run cron.schedule with '30 seconds' / '20 seconds'.
-- cron.schedule() with an existing jobname updates that job in place (same jobid).
-- =============================================================================

SELECT cron.schedule(
    'redispatch-stalled-searching-orders',
    '*/1 * * * *',
    'SELECT public.redispatch_stalled_searching_orders();'
);

SELECT cron.schedule(
    'redispatch-freed-riders',
    '45 seconds',
    'SELECT public.redispatch_freed_riders();'
);
