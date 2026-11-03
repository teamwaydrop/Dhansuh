-- =============================================================================
-- PRE-PRO REALTIME AMPLIFIER CLEANUP  (only the VERIFIED, clearly-GREEN items)
-- Ref: docs/PERF_prePro_realtime_cleanup_audit.md
-- File: supabase/migrations/20260909000000_pre_pro_realtime_amplifier_cleanup.sql
--
-- CHANGE 1: drop 2 permissive orders SELECT policies that are provable subsets
--   of "Allow users to view their own or assigned orders" (P3):
--     user_can_view_own_orders     == P3 disjunct 1 (auth.uid() = user_id), byte-for-byte
--     rider_can_view_assigned_orders == P3 disjunct 2 (riders.id is PK => IN(subquery ids) <=> EXISTS)
--   Result set unchanged for every role. orders has 0 restrictive policies.
--
-- CHANGE 2: users / notifications / rider_assignments REPLICA IDENTITY FULL -> DEFAULT.
--   0 subscribers of these 3 read payload.oldRecord; no production DELETE path that matters;
--   INSERT/UPDATE realtime delivery preserved; no trigger depends on replica identity.
--
-- NOT changed: orders RI, riders RI, any other policy, grants, triggers, indexes,
--   data, cron, publication membership.
-- =============================================================================

-- CHANGE 1
DROP POLICY IF EXISTS "rider_can_view_assigned_orders" ON public.orders;
DROP POLICY IF EXISTS "user_can_view_own_orders" ON public.orders;

-- CHANGE 2 (guarded -- only if currently FULL)
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
