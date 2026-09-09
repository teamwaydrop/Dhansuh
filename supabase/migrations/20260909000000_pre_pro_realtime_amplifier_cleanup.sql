-- =============================================================================
-- PRE-PRO REALTIME AMPLIFIER CLEANUP  (only the VERIFIED, clearly-GREEN items)
--
-- Ref: docs/PERF_prePro_realtime_cleanup_audit.md
--
-- Two independent, low-risk changes. Both are ADDITIVE to behaviour (no client
-- code depends on what changes), fully reversible, idempotency-guarded.
--
-- CHANGE 1  --  orders: drop 2 permissive SELECT policies that are provable
--               subsets of a third (no access gained or lost by ANY role).
--
--   Live SELECT policy set on public.orders (permissive, role authenticated):
--     P1 "Allow travellers to browse searching intercity orders"
--          order_status='searching' AND order_type LIKE 'intercity%'
--     P2 "Allow travellers to view orders tied to active intercity requests"
--          EXISTS(intercity_requests ir JOIN riders r ON r.id=ir.traveller_id
--                 WHERE ir.parcel_id=orders.id AND r.user_id=(SELECT auth.uid())
--                   AND ir.status NOT IN ('cancelled','rejected','expired'))
--     P3 "Allow users to view their own or assigned orders"
--          (SELECT auth.uid())=user_id
--          OR EXISTS(riders r WHERE r.id=orders.rider_id
--                    AND r.user_id=(SELECT auth.uid()))
--          OR check_is_order_candidate_rider(id, (SELECT auth.uid()))
--     P4 "admin_can_select_orders"          is_admin()
--     P5 "rider_can_view_assigned_orders"   rider_id IN (SELECT riders.id
--                                             FROM riders
--                                             WHERE riders.user_id=(SELECT auth.uid()))
--     P6 "user_can_view_own_orders"         (SELECT auth.uid())=user_id
--
--   Permissive => a row is visible iff (P1 OR P2 OR P3 OR P4 OR P5 OR P6).
--
--   P6 == P3's first disjunct, byte-for-byte  ->  P6 ⊆ P3.
--   P5 (rider_id IN (SELECT id FROM riders WHERE user_id=uid)) is TRUE iff
--     ∃ a riders row x with x.id=orders.rider_id AND x.user_id=uid.
--   P3's second disjunct (EXISTS(riders r WHERE r.id=orders.rider_id
--     AND r.user_id=uid)) is TRUE under the exact same condition
--     (riders.id is the PK => "IN (list of ids)" and "EXISTS(matching row)"
--      are equivalent; NULL rider_id, empty subquery, and NULL uid all yield
--      false on BOTH sides).                    ->  P5 ⊆ P3.
--
--   Therefore  (P1..P6)  ==  (P1 OR P2 OR P3 OR P4).  Dropping P5 and P6
--   removes NOTHING for any role (passenger / owner / assigned rider /
--   candidate rider / active-intercity participant / admin); service_role
--   bypasses RLS entirely. REST SELECT, Realtime RLS delivery, and every
--   `.from('orders').select()` return the identical row set.
--
--   Benefit: one fewer permissive-policy expression to evaluate on the
--   busiest Realtime table per subscriber per event (and on every orders
--   SELECT / REST read).
--
-- CHANGE 2  --  users / notifications / rider_assignments: REPLICA IDENTITY
--               FULL -> DEFAULT.
--
--   Verified against HEAD 418b1b4 (Dart + Edge Functions):
--     * NO subscriber of any of these 3 tables reads payload.oldRecord /
--       payload.old (grep: the only oldRecord readers are 5 `riders`
--       consumers + 4 `orders` consumers -- neither table is touched here).
--     * users : never DELETEd in production (delete_own_account nulls fields;
--       orders.user_id is ON DELETE RESTRICT). Both consumers
--       (user_session_service, home_tab) are event:update, id= (PK) filter,
--       read newRecord only -> identical under DEFAULT.
--     * notifications : the only production DELETE is delete_own_account
--       (which also logs the user out via users.deleted_at). The badge
--       subscription (event:all, user_id=) is callback = refresh(); it needs
--       INSERT (new notification) + UPDATE (mark-read) events, both fully
--       delivered under DEFAULT. Losing the (never-used) filtered DELETE
--       event has no functional effect.
--     * rider_assignments : production NEVER deletes rows (lifecycle sets
--       assignment_status='expired'; only the load-testing QA function
--       DELETEs). The dispatch/acceptance critical path is INSERT
--       (assignment_status='sent') + UPDATE (accepted/rejected/expired),
--       both fully delivered under DEFAULT (INSERT always carries the full
--       new row; UPDATE carries the full newRecord; PK / newRecord-column
--       filters evaluate fine). incoming_order_card uses event:update +
--       id= (PK) filter.
--     * Triggers: none on these 3 tables depend on replica identity
--       (trigger OLD/NEW is executor-provided, independent of RI; and none
--       fire on DELETE anyway).
--     * RLS: unchanged. With RLS enabled, Realtime already delivers
--       payload.old as PK-only regardless of RI, so clients see no change.
--
--   Benefit: every UPDATE / DELETE to these 3 tables logs only the PK as the
--   old tuple instead of the full row => ~half the WAL / list_changes decode
--   payload for notifications (7.4k lifetime UPDATEs, wide rows),
--   rider_assignments (3.1k), users (1.9k).
--
-- EXPLICITLY NOT CHANGED HERE (verified NOT clearly-GREEN):
--   * orders REPLICA IDENTITY  -- 4 consumers read payload.oldRecord
--     (rider_home_tab:824, intercity_bookings_screen:199,
--      rider_active_order_screen:1293-95, home_tab:1024 DELETE handler);
--     safety cannot be proven read-only without a live payload capture.
--   * riders REPLICA IDENTITY  -- 5 consumers depend on payload.oldRecord
--     (explicitly out of scope).
--   * P1..P4 orders policies    -- reference different tables/functions;
--     merging is error-prone and not needed.
--   * unused indexes            -- geo / device / expiry columns; a rare
--     admin/feature query cannot be ruled out read-only.
--
-- ROLLBACK: see the commented block at the end of this file.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- CHANGE 1: drop the 2 redundant permissive SELECT policies on public.orders.
--   (No IF-not-exists guard needed on DROP POLICY IF EXISTS -- it is a no-op
--    if already gone, so this migration is safely re-runnable.)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "rider_can_view_assigned_orders" ON public.orders;
DROP POLICY IF EXISTS "user_can_view_own_orders" ON public.orders;


-- -----------------------------------------------------------------------------
-- CHANGE 2: users / notifications / rider_assignments  FULL -> DEFAULT.
--   Guarded -- only change if currently FULL. Safe to re-run.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    t text;
    ri_list text[] := ARRAY['users', 'notifications', 'rider_assignments'];
    cur "char";
BEGIN
    FOREACH t IN ARRAY ri_list LOOP
        SELECT c.relreplident INTO cur
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = t;

        IF cur IS NULL THEN
            RAISE NOTICE 'RI: public.% not found -- skipped', t;
        ELSIF cur = 'f' THEN
            EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY DEFAULT', t);
            RAISE NOTICE 'RI: public.% FULL -> DEFAULT', t;
        ELSE
            RAISE NOTICE 'RI: public.% replica identity already % -- skipped', t, cur;
        END IF;
    END LOOP;
END $$;


-- =============================================================================
-- ROLLBACK (run manually to restore the exact pre-cleanup state):
--
--   -- CHANGE 1: recreate the 2 policies (phase10d initplan-wrapped form,
--   --           which is what was live before this migration):
--   CREATE POLICY "rider_can_view_assigned_orders" ON public.orders
--       FOR SELECT TO authenticated
--       USING (rider_id IN ( SELECT riders.id FROM riders
--                            WHERE riders.user_id = ( SELECT auth.uid() AS uid) ));
--   CREATE POLICY "user_can_view_own_orders" ON public.orders
--       FOR SELECT TO authenticated
--       USING (( SELECT auth.uid() AS uid) = user_id);
--
--   -- CHANGE 2: restore FULL replica identity:
--   ALTER TABLE public.users             REPLICA IDENTITY FULL;
--   ALTER TABLE public.notifications     REPLICA IDENTITY FULL;
--   ALTER TABLE public.rider_assignments REPLICA IDENTITY FULL;
--
-- (Nothing else is touched -- no table data, no other RLS policy, no grant,
--  no trigger, no function, no index, no cron, no publication membership,
--  no setting.)
-- =============================================================================
