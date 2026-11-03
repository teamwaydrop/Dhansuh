
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
