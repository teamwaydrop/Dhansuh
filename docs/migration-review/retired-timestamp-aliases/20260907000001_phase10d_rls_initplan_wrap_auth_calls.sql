-- Migration: wrap bare auth.<fn>() calls in RLS policies as (select auth.<fn>()).
-- Date: 2026-09-07
-- Source: PHASE 10B Supabase Performance Diagnostics (§6a), advisor `auth_rls_initplan`
--         (WARN x81). Verified 2026-09-07 against live pg_policies on project
--         yvwpchffctiagevpqgwy.
--
-- ============================================================================================
-- WHAT THIS DOES  (and, just as importantly, what it does NOT do)
-- ============================================================================================
-- For every RLS policy in schema `public` whose USING / WITH CHECK expression calls
-- `auth.uid()`, `auth.role()`, `auth.jwt()` or `auth.email()` WITHOUT the `(select ...)`
-- wrapper, this replaces each such call `auth.X()` with `(select auth.X())` and re-issues the
-- policy via `ALTER POLICY ... USING/WITH CHECK`.
--
-- This is the transformation documented by Supabase itself
-- (https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select):
-- `auth.uid()` is STABLE, so `(select auth.uid())` is evaluated ONCE per statement as an
-- InitPlan instead of once per row. Same value, same visibility, same permissions, same query
-- results -- only the per-row re-evaluation cost is removed.
--
-- It does NOT:
--   * merge, add, drop, rename, or re-scope any policy (roles, cmd, permissive/restrictive
--     are all preserved -- ALTER POLICY cannot change them and none are named here);
--   * touch any SECURITY DEFINER function, trigger, view, or the realtime publication;
--   * change any policy that is already wrapped (the WHERE clause skips those -- e.g.
--     public.user_device_tokens."Users can manage their own device tokens", already
--     `(( SELECT auth.uid() AS uid) = user_id)`, is left untouched);
--   * alter the boolean structure of any predicate -- the regex only ever expands a
--     zero-argument function call into a scalar subquery returning that same call, which
--     cannot change operator precedence or paren balance.
--
-- The 81 policies affected (table :: policy), as observed on 2026-09-07:
--   admin_logs :: admin_logs_admin_insert (auth.email())
--   admins :: admins_self_select (auth.email())
--   cod_settlement_ledger :: Riders can view their own COD settlement ledger
--   data_deletion_requests :: Users can create their own deletion request
--   data_deletion_requests :: Users can view their own deletion requests
--   government_tax_ledger :: government_tax_ledger_read_own
--   intercity_requests :: Allow request participants to create requests
--   intercity_requests :: Allow request participants to update safe fields
--   intercity_requests :: Allow request participants to view requests
--   notifications :: Users can update their own notifications
--   notifications :: Users can view their own notifications
--   order_assignment_logs :: Allow riders and orders owners to view logs
--   order_chat_messages :: Allow chat participants to send messages
--   order_chat_messages :: Allow chat participants to view messages
--   order_chat_messages :: Allow sender to delete own chat messages
--   order_chat_messages :: Allow sender to update own chat messages
--   order_verifications :: Allow assigned rider to insert order verifications
--   order_verifications :: Allow participants to view order verifications
--   orders :: Allow passengers and assigned riders to update orders
--   orders :: Allow travellers to view orders tied to active intercity requests
--   orders :: Allow users to view their own or assigned orders
--   orders :: rider_can_view_assigned_orders
--   orders :: user_can_update_own_order
--   orders :: user_can_view_own_orders
--   payment_disputes :: Admins can resolve disputes
--   payment_disputes :: Order participants can raise a dispute
--   payment_disputes :: Order participants can view their own disputes
--   promo_code_users :: Users can view their own promo assignments
--   promo_codes :: Allow read access to active and applicable promos
--   reward_cycles :: reward_cycles_read_own
--   reward_offers :: reward_offers_read_when_unlocked
--   rider_assignments :: Allow passengers to insert assignments for their own orders
--   rider_assignments :: Allow passengers to update assignments for their own orders
--   rider_assignments :: Allow passengers to view assignments for their own orders
--   rider_assignments :: Allow riders to insert their own assignments
--   rider_assignments :: Allow riders to update their own assignments
--   rider_assignments :: Allow riders to view their own assignments
--   rider_assignments :: Riders can view own assignments
--   rider_daily_activity :: Riders can view their own daily activity
--   rider_kyc :: Riders can insert own KYC
--   rider_kyc :: Riders can view own KYC
--   rider_kyc :: Riders view own KYC or admin support view any
--   rider_kyc :: Users can create own kyc
--   rider_kyc :: Users can update own kyc
--   rider_kyc :: Users can view own kyc
--   rider_kyc_retention_archive :: Admin support can view retained KYC archive
--   rider_payout_accounts :: Riders can delete their own payout account
--   rider_payout_accounts :: Riders can view their own payout account
--   rider_payout_accounts :: rider_insert_own_payout_account
--   rider_payout_accounts :: rider_select_own_payout_account
--   rider_payout_updates_log :: Riders can view their own payout updates log
--   rider_reviews :: Riders can insert reviews for their own orders
--   rider_reviews :: Users and riders can view reviews
--   rider_reviews :: Users can insert reviews for their own orders
--   rider_travel_plans :: Allow authenticated users to view active travel plans
--   rider_travel_plans :: Allow riders to delete their own travel plans
--   rider_travel_plans :: Allow riders to insert their own travel plans
--   rider_travel_plans :: Allow riders to update their own travel plans
--   rider_vehicles :: Riders can insert own vehicles
--   rider_vehicles :: Riders can view own vehicles
--   rider_withdrawal_events :: Riders can view their own withdrawal events
--   rider_withdrawal_events :: Users can view own withdrawal events
--   rider_withdrawals :: Riders can view their own withdrawals
--   rider_withdrawals :: Users can view own withdrawals
--   riders :: Allow authenticated users to view online riders
--   riders :: Allow riders to update their own profile
--   riders :: Riders can update own rider profile
--   riders :: Riders can view own rider profile
--   riders :: Users can view own rider profile
--   travel_matches :: Participants can view their own travel matches
--   trip_share_tokens :: Allow owners and riders of orders to manage share tokens
--   user_devices :: Allow users to insert their own devices
--   user_devices :: Allow users to select their own devices
--   user_devices :: Allow users to update their own devices
--   user_promo_usages :: Users can record their own promo usage
--   user_promo_usages :: Users can view their own promo usages
--   users :: Allow travellers to view sender profile for active intercity requests
--   users :: Users can insert own profile
--   users :: Users can update own profile
--   users :: Users can view own profile
--   wallet_transactions :: Riders can view their own wallet transactions
--
-- The rewrite is applied dynamically (rather than as 81 hand-transcribed ALTER statements)
-- so it round-trips each policy through Postgres' own canonical deparser -- eliminating any
-- risk of a transcription error changing a predicate. Every statement it runs is echoed with
-- RAISE NOTICE, and the migration fails loudly at the end if any unwrapped call remains.
-- ============================================================================================

SET LOCAL search_path = public, extensions;

DO $mig$
DECLARE
  r        record;
  new_qual text;
  new_chk  text;
  stmt     text;
  n        int := 0;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname, qual, with_check
    FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        regexp_replace(coalesce(qual,''),       '\(\s*select\s+auth\.(uid|role|jwt|email)\(\)[^)]*\)', '', 'gi') ~* 'auth\.(uid|role|jwt|email)\(\)'
        OR regexp_replace(coalesce(with_check,''), '\(\s*select\s+auth\.(uid|role|jwt|email)\(\)[^)]*\)', '', 'gi') ~* 'auth\.(uid|role|jwt|email)\(\)'
      )
    ORDER BY tablename, policyname
  LOOP
    new_qual := regexp_replace(r.qual,       'auth\.(uid|role|jwt|email)\(\)', '(select auth.\1())', 'g');
    new_chk  := regexp_replace(r.with_check, 'auth\.(uid|role|jwt|email)\(\)', '(select auth.\1())', 'g');

    stmt := format('ALTER POLICY %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
    IF new_qual IS NOT NULL THEN
      stmt := stmt || format(' USING (%s)', new_qual);
    END IF;
    IF new_chk IS NOT NULL THEN
      stmt := stmt || format(' WITH CHECK (%s)', new_chk);
    END IF;

    RAISE NOTICE 'rls_initplan: %', stmt;
    EXECUTE stmt;
    n := n + 1;
  END LOOP;

  RAISE NOTICE 'rls_initplan: rewrote % policies', n;

  -- Fail the migration if any policy in public still has an unwrapped auth.<fn>() call.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND (
        regexp_replace(coalesce(qual,''),       '\(\s*select\s+auth\.(uid|role|jwt|email)\(\)[^)]*\)', '', 'gi') ~* 'auth\.(uid|role|jwt|email)\(\)'
        OR regexp_replace(coalesce(with_check,''), '\(\s*select\s+auth\.(uid|role|jwt|email)\(\)[^)]*\)', '', 'gi') ~* 'auth\.(uid|role|jwt|email)\(\)'
      )
  ) THEN
    RAISE EXCEPTION 'rls_initplan: unwrapped auth.<fn>() call still present after rewrite';
  END IF;
END
$mig$;
