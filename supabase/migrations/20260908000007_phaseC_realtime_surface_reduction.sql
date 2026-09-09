-- =============================================================================
-- PHASE C — STAGE C10-1 + C10-2: Realtime publication surface reduction
--                                (ADDITIVE to app behaviour, fully reversible)
--
-- Ref: docs/PERF_phaseC_realtime_capacity_audit.md
--
-- WHY:
--   realtime.list_changes (WAL decode) is ~43% of total DB time on the current
--   (Free-tier) instance and is the workload that saturates first under a
--   multi-ride burst. Every table in the supabase_realtime publication has its
--   INSERT/UPDATE/DELETE WAL decoded and RLS-scanned on every change, whether or
--   not any client subscribes to it.
--
-- WHAT C10-1 DOES:
--   Removes 8 tables from the supabase_realtime publication. Each was verified
--   (2026-09-08, against HEAD 418b1b4) to have NO realtime subscriber:
--     - no RealtimeManager.instance.subscribe(table: ...) call
--     - no raw supabase.channel(...).onPostgresChanges(table: ...) call
--     - no Edge Function opens a realtime channel at all (verified: none do)
--   and all 8 were added to the publication via the Supabase dashboard Realtime
--   toggle, NOT by any migration (no migration in supabase/migrations/ ever runs
--   `ALTER PUBLICATION supabase_realtime ADD TABLE` for any of them).
--
--   Removed:
--     public.order_assignment_logs       (ins 3772 / upd 1087 / del 1282; DEFAULT RI)
--     public.rider_payout_accounts       (ins   29 / upd  132 / del   38; DEFAULT RI)
--     public.rider_subscription_history  (ins   32 / upd   19 / del   74; DEFAULT RI)
--     public.pricing_zones               (ins    3 / upd    8 / del    0; DEFAULT RI)
--     public.order_status_history        (ins 4188 / upd    0 / del 1455; DEFAULT RI)
--     public.rider_payout_updates_log    (ins   48 / upd    0 / del    4; DEFAULT RI)
--     public.rider_withdrawal_events     (ins  143 / upd    0 / del    3; DEFAULT RI)
--     public.rider_reviews               (ins  539 / upd    0 / del  511; DEFAULT RI)
--
--   Removing a table from a publication changes ONLY what logical decoding emits
--   for that table. It does NOT touch the table, its rows, its RLS, its grants,
--   its triggers, its indexes, or any write path. `.from('<table>')` REST reads
--   and writes are completely unaffected.
--
-- WHAT C10-2 DOES:
--   Sets REPLICA IDENTITY FULL -> DEFAULT on the two published tables that carry
--   FULL pointlessly:
--     public.order_chat_messages   (ins 704 / upd 0 / del 229; RLS on)
--     public.order_verifications   (ins  98 / upd 0 / del   0; RLS on; insert-only)
--   Both have RLS enabled, so Supabase Realtime already delivers payload.old as
--   PK-only regardless of replica identity. Verified consumers:
--     - order_chat_messages: order_chat_screen._subscribeChat reads payload
--       .newRecord ONLY (`if (newMsg.isEmpty) return;` early-outs on DELETE and
--       never touches payload.oldRecord); admin_support_chats_screen subscribes
--       event: insert only. Both triggers on the table are BEFORE/AFTER INSERT
--       (trigger_new_chat_message, trigger_prevent_chat_before_intercity_
--       acceptance) -- neither reads OLD, and trigger OLD visibility is
--       independent of replica identity regardless.
--     - order_verifications: NO realtime subscriber (polled via REST). 0 triggers.
--   Net effect: identical realtime payloads to clients; DELETE WAL records for
--   these two tables shrink from full-old-row to PK-only.
--
-- WHAT THIS MIGRATION DOES NOT DO (explicit):
--   * Does NOT change riders / orders / notifications / users / rider_assignments
--     replica identity (still FULL -- a later, separately-verified stage).
--   * Does NOT remove any other publication member.
--   * Does NOT touch RLS, grants, triggers, functions, indexes, cron, pg_net,
--     max_connections, the pooler, or any Supabase plan/setting.
--   * Does NOT move orders.dispatch_worker_running / dispatch_state.
--   * Does NOT touch application code, GPS architecture, completion/fare logic,
--     or the A1 bridge.
--
-- IDEMPOTENT: every step is guarded (DROP only if currently a member; RI change
-- only if currently FULL). Safe to re-run.
--
-- ROLLBACK: see the commented block at the end of this file.
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


-- =============================================================================
-- ROLLBACK (run manually to restore the exact pre-C10 state):
--
--   -- C10-1: re-add the 8 tables to the publication
--   DO $$
--   DECLARE
--       t text;
--       readd_list text[] := ARRAY[
--           'order_assignment_logs','rider_payout_accounts','rider_subscription_history',
--           'pricing_zones','order_status_history','rider_payout_updates_log',
--           'rider_withdrawal_events','rider_reviews'
--       ];
--   BEGIN
--       FOREACH t IN ARRAY readd_list LOOP
--           IF NOT EXISTS (
--               SELECT 1 FROM pg_publication_tables
--               WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t
--           ) THEN
--               EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
--           END IF;
--       END LOOP;
--   END $$;
--
--   -- C10-2: restore FULL replica identity
--   ALTER TABLE public.order_chat_messages REPLICA IDENTITY FULL;
--   ALTER TABLE public.order_verifications REPLICA IDENTITY FULL;
--
-- (Nothing else needs rollback -- no table data, RLS, grant, trigger, function,
--  index, cron, or setting was touched.)
-- =============================================================================
