-- =============================================================================
-- BASELINE MIGRATION PROPOSAL, PART 2 (NOT YET APPLIED ANYWHERE)
-- =============================================================================
-- Companion to 20260529000000_baseline_foundational_schema.sql.
--
-- These 5 policies exist in production (prod_schema_dump.sql) but were never
-- captured by any migration, same as everything in part 1. They could NOT go
-- in part 1 because they target tables that are themselves created by later
-- migrations, not by the baseline:
--   - rider_payout_accounts  -> created in 20260530000000_rider_payout_accounts.sql
--   - rider_withdrawals,
--     rider_withdrawal_events -> created in 20260530000001_rider_withdrawals.sql
--
-- This file is timestamped after every migration currently in
-- supabase/migrations/ so that, whichever point it is actually inserted at,
-- its target tables are guaranteed to already exist. If you promote this
-- into supabase/migrations/, it only needs to sort after
-- 20260530000000/20260530000001 - it does not need to be the very last file,
-- but leaving it last is the simplest safe placement.
-- =============================================================================

CREATE POLICY "rider_insert_own_payout_account" ON "public"."rider_payout_accounts" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "rider_select_own_payout_account" ON "public"."rider_payout_accounts" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));

CREATE POLICY "rider_update_own_payout_account" ON "public"."rider_payout_accounts" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can view own withdrawal events" ON "public"."rider_withdrawal_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."rider_withdrawals" "rw"
  WHERE (("rw"."id" = "rider_withdrawal_events"."withdrawal_id") AND ("rw"."user_id" = "auth"."uid"())))));

CREATE POLICY "Users can view own withdrawals" ON "public"."rider_withdrawals" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));
