-- =====================================================================
-- NEW FEATURE (Phase 3 Financial Revenue Audit): "Cash to be Paid"
-- (riders.cod_pending_amount) has never had a collection mechanism.
-- =====================================================================
-- cod_pending_amount is real company revenue -- the platform's commission share on
-- orders a driver settled by collecting cash/personal-UPI directly (see
-- credit_rider_for_completed_order(), 20260724000003_atomic_rider_completion_credit.sql,
-- which is the ONLY place this column is ever written -- it is incremented there and,
-- confirmed by an exhaustive grep across every migration and Edge Function, never
-- decremented or collected anywhere). It already correctly blocks new dispatch via
-- is_rider_blocked_by_cod_limit() and is already displayed to the driver ("Cash to
-- Paid" stat, rider_earnings_tab.dart), but there is no way for a driver to ever pay
-- it off.
--
-- This migration adds exactly the payment/ledger half of that flow, mirroring the
-- already-working, already-proven government_tax_due_balance / apply_government_tax_
-- payment() pattern byte-for-byte (same idempotency guarantee, same "pay full
-- balance only" v1 scope, same SECURITY DEFINER + search_path hardening). The
-- `cod_settlement` payment_for_enum value already existed (added in
-- 20260612000006_update_payment_for_enum.sql) and the Flutter client already has a
-- 'cod_settlement' push-notification deep-link handler
-- (notification_service.dart:516) -- both were reserved for this exact feature and
-- never wired up. Edge Function changes (create-payment, cashfree-webhook,
-- verify-payment) reusing this RPC are deployed in the same release.
--
-- Money path: driver pays via Cashfree Payment Gateway (Orders API) -> webhook/poll
-- confirms -> this RPC decrements cod_pending_amount -> Cashfree settles the
-- collected amount to WayDrop's own registered bank account automatically (T+2,
-- confirmed via Cashfree's own settlement documentation) -- no Payouts/Payment
-- Links/QR/Virtual Account involved, exactly the same mechanism already used for
-- tax_due and subscription.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.cod_settlement_ledger (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    rider_id uuid NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
    payment_id uuid REFERENCES public.payments(id) ON DELETE SET NULL,
    entry_type text NOT NULL CHECK (entry_type IN ('COD_SETTLEMENT_PAYMENT')),
    -- Always negative -- reduces cod_pending_amount. Kept as a signed ledger (rather
    -- than just decrementing the column) so this exact payment event is independently
    -- auditable, matching government_tax_ledger's own rationale.
    amount numeric NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cod_settlement_ledger_rider_id
    ON public.cod_settlement_ledger USING btree (rider_id, created_at DESC);

-- Exactly one COD_SETTLEMENT_PAYMENT entry per payment_id -- the DB-level guarantee
-- that a duplicate webhook delivery racing verify-payment's poll (both call the same
-- RPC below for the same payment) can never double-apply the same payment.
CREATE UNIQUE INDEX IF NOT EXISTS idx_cod_settlement_ledger_one_payment
    ON public.cod_settlement_ledger (payment_id)
    WHERE entry_type = 'COD_SETTLEMENT_PAYMENT';

ALTER TABLE public.cod_settlement_ledger ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Riders can view their own COD settlement ledger"
ON public.cod_settlement_ledger
FOR SELECT
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.riders r WHERE r.id = cod_settlement_ledger.rider_id AND r.user_id = auth.uid())
);

REVOKE ALL ON public.cod_settlement_ledger FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cod_settlement_ledger TO authenticated;
GRANT ALL ON public.cod_settlement_ledger TO service_role;

-- =====================================================================
-- apply_cod_settlement_payment: byte-for-byte the same idempotency pattern as
-- apply_government_tax_payment (20260726000004_government_tax_due_functions.sql),
-- targeting cod_pending_amount instead of government_tax_due_balance.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.apply_cod_settlement_payment(p_rider_id uuid, p_payment_id uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_existing record;
    v_new_balance numeric;
BEGIN
    SELECT amount INTO v_existing
    FROM public.cod_settlement_ledger
    WHERE payment_id = p_payment_id AND entry_type = 'COD_SETTLEMENT_PAYMENT';

    IF FOUND THEN
        SELECT cod_pending_amount INTO v_new_balance FROM public.riders WHERE id = p_rider_id;
        RETURN jsonb_build_object('applied', true, 'already_existed', true, 'amount', -v_existing.amount, 'new_balance', v_new_balance);
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'apply_cod_settlement_payment: amount must be positive (got %)', p_amount;
    END IF;

    INSERT INTO public.cod_settlement_ledger (rider_id, payment_id, entry_type, amount)
    VALUES (p_rider_id, p_payment_id, 'COD_SETTLEMENT_PAYMENT', -p_amount)
    ON CONFLICT (payment_id) WHERE entry_type = 'COD_SETTLEMENT_PAYMENT' DO NOTHING;

    IF NOT FOUND THEN
        SELECT amount INTO v_existing FROM public.cod_settlement_ledger
        WHERE payment_id = p_payment_id AND entry_type = 'COD_SETTLEMENT_PAYMENT';
        SELECT cod_pending_amount INTO v_new_balance FROM public.riders WHERE id = p_rider_id;
        RETURN jsonb_build_object('applied', true, 'already_existed', true, 'amount', -v_existing.amount, 'new_balance', v_new_balance);
    END IF;

    UPDATE public.riders
    SET cod_pending_amount = GREATEST(cod_pending_amount - p_amount, 0),
        updated_at = now()
    WHERE id = p_rider_id
    RETURNING cod_pending_amount INTO v_new_balance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'apply_cod_settlement_payment: rider % not found', p_rider_id;
    END IF;

    RETURN jsonb_build_object('applied', true, 'already_existed', false, 'amount', p_amount, 'new_balance', v_new_balance);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.apply_cod_settlement_payment(uuid, uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_cod_settlement_payment(uuid, uuid, numeric) TO service_role;
