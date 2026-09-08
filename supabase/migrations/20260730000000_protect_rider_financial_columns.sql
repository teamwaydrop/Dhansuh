-- Migration: Lock down riders' own financial/subscription/verification columns to
-- server-only (service_role) writes.
-- Date: 2026-07-30
--
-- CONTEXT: "Allow riders to update their own profile" (20260531000003_fix_find_nearby_riders.sql)
-- is a row-level-only UPDATE policy (USING/WITH CHECK: auth.uid() = user_id) with no column
-- restriction, and the table-level GRANT ("... ,UPDATE ON TABLE public.riders TO authenticated",
-- 20260529000000_baseline_foundational_schema.sql) has no column list either. Unlike orders
-- (protect_order_financial_columns) and rider_payout_accounts (protect_rider_upi_verification),
-- riders itself has never had a guard trigger. Net effect: any authenticated rider can issue a
-- direct REST PATCH against their own row and self-set wallet_balance, subscription_active/
-- subscription_expires_at, commission_waiver_active, government_tax_due_balance, cod_limit,
-- cod_pending_amount, or is_verified -- bypassing Cashfree payment confirmation, the Government
-- Tax Due block, and COD-limit/KYC enforcement entirely. Every legitimate writer of these columns
-- (cashfree-webhook, verify-payment, apply_order_government_tax, apply_government_tax_payment,
-- credit_rider_for_completed_order, initiate_withdrawal/fail_withdrawal/complete_withdrawal) already
-- runs exclusively under service_role (confirmed: none of these are GRANTed to authenticated), so
-- this trigger closes the gap without touching any existing business logic.

CREATE OR REPLACE FUNCTION public.protect_rider_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role' THEN
        IF NEW.wallet_balance IS DISTINCT FROM OLD.wallet_balance
           OR NEW.cod_pending_amount IS DISTINCT FROM OLD.cod_pending_amount
           OR NEW.cod_limit IS DISTINCT FROM OLD.cod_limit
           OR NEW.subscription_active IS DISTINCT FROM OLD.subscription_active
           OR NEW.subscription_expires_at IS DISTINCT FROM OLD.subscription_expires_at
           OR NEW.commission_waiver_active IS DISTINCT FROM OLD.commission_waiver_active
           OR NEW.government_tax_due_balance IS DISTINCT FROM OLD.government_tax_due_balance
           OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
        THEN
            RAISE EXCEPTION 'Direct modification of rider financial/subscription columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS protect_rider_financial_columns_trigger ON public.riders;
CREATE TRIGGER protect_rider_financial_columns_trigger
BEFORE UPDATE ON public.riders
FOR EACH ROW
EXECUTE FUNCTION public.protect_rider_financial_columns();
