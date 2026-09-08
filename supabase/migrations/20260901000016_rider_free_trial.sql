-- =============================================================================
-- WayDrop launch offer: one-time 30-day free trial for new partners.
--
-- BUSINESS REQUIREMENT: every new partner's FIRST "Go Online" starts a one-time,
-- 30-day, zero-commission trial. No payment, no Cashfree checkout. Must be
-- enforced server-side (not just Flutter UI), must be exactly one-time per
-- partner (surviving offline/online toggles, reinstall, logout/in, new device),
-- and must not touch existing paid-subscription behavior.
--
-- DESIGN: rather than adding a parallel commission-waiver code path, the trial
-- reuses the EXACT mechanism that already grants 0% commission everywhere in
-- the codebase -- riders.subscription_active / riders.subscription_expires_at.
-- Every commission-waiver check (accept-order/index.ts, complete_order_and_settle,
-- complete_intercity_parcel_delivery, apply_order_government_tax,
-- intercity_parcel_payment_confirmation_step) already reads exactly these two
-- columns from `riders` and waives commission when active+unexpired -- so
-- activating the trial by setting them requires ZERO changes to any of that
-- already-proven, revenue-critical logic.
--
-- free_trial_started_at / free_trial_expires_at / free_trial_used are kept as
-- separate, permanent bookkeeping columns (never reset) purely so:
--   1. "already used" can be checked independent of current expiry (an EXPIRED
--      trial must never be re-grantable, unlike subscription_expires_at which
--      is expected to lapse and be re-extended by real purchases).
--   2. The Flutter UI can tell a "free trial" state apart from a "paid MAX"
--      state for messaging purposes (the banner/sheet copy differs), without
--      guessing from subscription_active alone.
-- =============================================================================

ALTER TABLE "public"."riders"
    ADD COLUMN IF NOT EXISTS "free_trial_started_at" timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "free_trial_expires_at" timestamp with time zone,
    ADD COLUMN IF NOT EXISTS "free_trial_used" boolean NOT NULL DEFAULT false;

-- =============================================================================
-- Extend the existing rider financial-column guard (20260730000000 /
-- 20260820000000) to also protect the 3 new columns -- otherwise a rider could
-- issue a direct REST PATCH against their own row (RLS's "Riders can update own
-- rider profile" policy has no column restriction) and self-grant/reset the
-- trial by writing free_trial_used=false or pushing free_trial_expires_at into
-- the future. Same bypass flag (app.bypass_rider_financial_guard), same
-- service_role escape hatch -- CREATE OR REPLACE preserves the existing GRANTs.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.protect_rider_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_rider_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.wallet_balance IS DISTINCT FROM OLD.wallet_balance
           OR NEW.cod_pending_amount IS DISTINCT FROM OLD.cod_pending_amount
           OR NEW.cod_limit IS DISTINCT FROM OLD.cod_limit
           OR NEW.subscription_active IS DISTINCT FROM OLD.subscription_active
           OR NEW.subscription_expires_at IS DISTINCT FROM OLD.subscription_expires_at
           OR NEW.commission_waiver_active IS DISTINCT FROM OLD.commission_waiver_active
           OR NEW.government_tax_due_balance IS DISTINCT FROM OLD.government_tax_due_balance
           OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
           OR NEW.free_trial_started_at IS DISTINCT FROM OLD.free_trial_started_at
           OR NEW.free_trial_expires_at IS DISTINCT FROM OLD.free_trial_expires_at
           OR NEW.free_trial_used IS DISTINCT FROM OLD.free_trial_used
        THEN
            RAISE EXCEPTION 'Direct modification of rider financial/subscription columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =============================================================================
-- activate_rider_free_trial(): the only way the 30-day trial can ever be
-- granted. Callable directly by the authenticated rider (GRANT ... TO
-- authenticated), same posture as complete_intercity_parcel_delivery -- takes
-- NO caller-supplied rider id, resolves the caller's own rider row via
-- auth.uid() only, so it can never be pointed at another partner's account.
--
-- Idempotent/one-time by construction: the row is locked (FOR UPDATE) and
-- free_trial_used is checked and flipped to true in the SAME transaction as
-- the grant, so two concurrent calls (e.g. a double-tap) can never both
-- succeed -- the second sees free_trial_used = true and no-ops.
--
-- Does not touch a currently-active PAID subscription: if the rider already
-- has subscription_active = true with a future subscription_expires_at, this
-- returns trial_activated = false / reason = 'already_subscribed' without
-- writing anything, so a real purchase is never replaced or shortened by the
-- trial. If a rider on an active trial later buys a real plan, the existing
-- computeSubscriptionExpiry() stacking logic in cashfree-webhook/verify-payment
-- (unchanged by this migration) simply adds the paid duration on top of
-- whatever subscription_expires_at already holds -- exactly the same as
-- stacking two paid purchases.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.activate_rider_free_trial()
RETURNS TABLE(
    trial_activated boolean,
    reason text,
    subscription_active boolean,
    subscription_expires_at timestamp with time zone,
    free_trial_expires_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rider RECORD;
    v_now timestamptz := now();
    v_expires timestamptz;
BEGIN
    -- Table-qualified: RETURNS TABLE(...) implicitly declares subscription_active /
    -- subscription_expires_at as PL/pgSQL variables in scope for the whole function body, which
    -- collide with the identically-named `riders` columns in a bare (unqualified) SELECT here --
    -- Postgres raises "column reference is ambiguous" (42702) at call time otherwise. Confirmed
    -- live against the TEST project during verification: the unqualified form fails on every call.
    SELECT r.id, r.free_trial_used, r.subscription_active, r.subscription_expires_at
    INTO v_rider
    FROM public.riders r
    WHERE r.user_id = auth.uid()
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'rider_not_found'::text, false, NULL::timestamptz, NULL::timestamptz;
        RETURN;
    END IF;

    IF v_rider.free_trial_used THEN
        RETURN QUERY SELECT false, 'trial_already_used'::text, v_rider.subscription_active, v_rider.subscription_expires_at, NULL::timestamptz;
        RETURN;
    END IF;

    IF v_rider.subscription_active IS TRUE
       AND v_rider.subscription_expires_at IS NOT NULL
       AND v_rider.subscription_expires_at > v_now
    THEN
        RETURN QUERY SELECT false, 'already_subscribed'::text, v_rider.subscription_active, v_rider.subscription_expires_at, NULL::timestamptz;
        RETURN;
    END IF;

    v_expires := v_now + interval '30 days';

    -- Transaction-local only -- never leaks to another request/connection. Safe here because
    -- this function performs its own authorization (auth.uid() row match) and its own eligibility
    -- decision (free_trial_used / already_subscribed checks above) rather than trusting a caller,
    -- same justification as credit_rider_for_completed_order's use of this same flag.
    PERFORM set_config('app.bypass_rider_financial_guard', 'true', true);

    UPDATE public.riders
    SET free_trial_used = true,
        free_trial_started_at = v_now,
        free_trial_expires_at = v_expires,
        subscription_active = true,
        subscription_expires_at = v_expires,
        updated_at = v_now
    WHERE id = v_rider.id;

    INSERT INTO public.rider_subscription_history (
        rider_id, amount, payment_status, payment_id, starts_at, expires_at, is_active
    ) VALUES (
        v_rider.id, 0, 'free_trial', NULL, v_now, v_expires, true
    );

    RETURN QUERY SELECT true, 'activated'::text, true, v_expires, v_expires;
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_rider_free_trial() TO authenticated;
