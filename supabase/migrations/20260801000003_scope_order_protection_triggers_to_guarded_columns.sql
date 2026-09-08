-- Migration: Scope the three unconditional BEFORE UPDATE triggers on public.orders to only fire
-- when the specific columns they guard are actually part of the UPDATE.
-- Date: 2026-08-01
--
-- ROOT CAUSE (WayDrop Progressive Degradation Audit, finding DB-4): protect_order_financial_columns_
-- trigger (20260724000004, latest column list from 20260730000002_protect_order_fare_columns.sql),
-- protect_order_state_columns_trigger (20260730000008_lock_order_status_and_otp_columns.sql), and
-- trg_orders_compliance_retention (20260612000003_compliance_adjustments.sql) are all
-- `BEFORE UPDATE ON public.orders FOR EACH ROW` with no column scoping -- they fire on every single
-- UPDATE to the busiest table in the schema (fare boosts, ETA-adjacent writes, chat handovers, live
-- location-adjacent touches), not just the specific state/financial transitions they actually guard.
--
-- SAFETY: this migration does NOT touch any of the three trigger FUNCTION bodies (no
-- CREATE OR REPLACE FUNCTION statements below) -- only the CREATE TRIGGER definitions, via
-- DROP TRIGGER + CREATE TRIGGER ... EXECUTE FUNCTION against the existing, unmodified functions.
-- This area of the schema has a well-documented history of production incidents caused by
-- CREATE OR REPLACE FUNCTION being rebased off a stale function body and silently dropping the
-- app.bypass_financial_guard / app.bypass_order_state_guard escape hatches (see
-- 20260725000002 and 20260725000007's headers) -- that failure mode is structurally impossible here
-- because the function bodies are never redefined by this migration.
--
-- Postgres's `UPDATE OF <columns>` trigger clause fires whenever any listed column appears in the
-- UPDATE statement's SET list, regardless of whether the value actually changes (matching, not
-- narrowing, the trigger body's own IS DISTINCT FROM checks) -- so for any UPDATE that does not
-- touch a guarded column, the trigger was already a guaranteed no-op under the old unscoped
-- definition. Column lists below were taken directly from each function's current, live guard
-- conditions (verified against the migration history, no columns omitted):
--
--   protect_order_financial_columns(): commission_amount, gst_amount, rider_earning,
--     commission_percentage, gst_percentage, actual_fare, boost_rider_earning,
--     boost_company_earning, payment_status, fare_payment_method, current_fare, final_fare,
--     boost_amount, boost_percentage
--   protect_order_state_columns(): order_status, pickup_otp, delivery_otp, rider_id
--   set_compliance_retention(): order_status (only column read by the function body)

DROP TRIGGER IF EXISTS protect_order_financial_columns_trigger ON public.orders;
CREATE TRIGGER protect_order_financial_columns_trigger
BEFORE UPDATE OF
    commission_amount, gst_amount, rider_earning, commission_percentage, gst_percentage,
    actual_fare, boost_rider_earning, boost_company_earning, payment_status, fare_payment_method,
    current_fare, final_fare, boost_amount, boost_percentage
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_financial_columns();

DROP TRIGGER IF EXISTS protect_order_state_columns_trigger ON public.orders;
CREATE TRIGGER protect_order_state_columns_trigger
BEFORE UPDATE OF order_status, pickup_otp, delivery_otp, rider_id
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_state_columns();

DROP TRIGGER IF EXISTS trg_orders_compliance_retention ON public.orders;
CREATE TRIGGER trg_orders_compliance_retention
BEFORE UPDATE OF order_status
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.set_compliance_retention();
