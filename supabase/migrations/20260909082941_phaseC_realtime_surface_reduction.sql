-- =============================================================================
-- PHASE C — STAGE C10-1 + C10-2: Realtime publication surface reduction
--                                (ADDITIVE to app behaviour, fully reversible)
-- Ref: docs/PERF_phaseC_realtime_capacity_audit.md
-- File: supabase/migrations/20260908000007_phaseC_realtime_surface_reduction.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C10-1: remove the 8 verified no-subscriber tables from supabase_realtime.
--        Guarded per table -- only DROP if it is currently a member.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    remove_list text[] := ARRAY[
        'order_assignment_logs',
        'rider_payout_accounts',
        'rider_subscription_history',
        'pricing_zones',
        'order_status_history',
        'rider_payout_updates_log',
        'rider_withdrawal_events',
        'rider_reviews'
    ];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        RAISE NOTICE 'publication supabase_realtime does not exist -- nothing to do';
        RETURN;
    END IF;

    FOREACH t IN ARRAY remove_list LOOP
        IF EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename = t
        ) THEN
            EXECUTE format('ALTER PUBLICATION supabase_realtime DROP TABLE public.%I', t);
            RAISE NOTICE 'C10-1: dropped public.% from supabase_realtime', t;
        ELSE
            RAISE NOTICE 'C10-1: public.% not a member of supabase_realtime -- skipped', t;
        END IF;
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- C10-2: FULL -> DEFAULT replica identity for the two published tables where
--        FULL is inert (RLS on both => client payload.old is PK-only already).
--        Guarded -- only change if currently FULL.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    ri_list text[] := ARRAY['order_chat_messages', 'order_verifications'];
    cur "char";
BEGIN
    FOREACH t IN ARRAY ri_list LOOP
        SELECT c.relreplident INTO cur
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = t;

        IF cur IS NULL THEN
            RAISE NOTICE 'C10-2: public.% not found -- skipped', t;
        ELSIF cur = 'f' THEN
            EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY DEFAULT', t);
            RAISE NOTICE 'C10-2: public.% REPLICA IDENTITY FULL -> DEFAULT', t;
        ELSE
            RAISE NOTICE 'C10-2: public.% replica identity already % -- skipped', t, cur;
        END IF;
    END LOOP;
END $$;
