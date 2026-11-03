-- =====================================================================
-- P0 FIX: orders INSERT had no financial/state-column guard, letting an
-- authenticated client fabricate a "paid"/"ongoing" order and mint wallet
-- credit for a rider they control.
-- =====================================================================
-- ROOT CAUSE (verified, not assumed): the two column-protection triggers
-- (protect_order_financial_columns, protect_order_state_columns) are both
-- `BEFORE UPDATE ON public.orders` only -- protect_order_financial_columns's
-- own body compares NEW.x IS DISTINCT FROM OLD.x, which is structurally
-- incapable of running as a BEFORE INSERT trigger (OLD does not exist on
-- INSERT). The only BEFORE INSERT trigger on orders
-- (20260611000002_prefixed_alphanumeric_codes.sql) only generates
-- order_code. The live INSERT policy ("Allow passengers to create orders",
-- 20260531000003_fix_find_nearby_riders.sql:225-229) is
-- `WITH CHECK (auth.uid() = user_id)` -- it does not constrain
-- order_status/payment_status/rider_id/current_fare/final_fare/rider_earning
-- at all.
--
-- FIX: a repo-wide grep of every `.from('orders').insert(...)` call site in
-- lib/ confirms the Flutter client NEVER inserts into orders directly --
-- order creation always goes through the create-order edge function
-- (service_role, which bypasses RLS entirely and is unaffected by this
-- change). Direct client INSERT into orders therefore has zero legitimate
-- use today, so the safest fix is to deny it outright rather than attempt to
-- allow-list columns on a codepath nothing legitimate uses.
-- =====================================================================

DROP POLICY IF EXISTS "Allow passengers to create orders" ON public.orders;

CREATE POLICY "Deny direct client orders insert (service-role only)"
ON public.orders
FOR INSERT
TO authenticated
WITH CHECK (false);
