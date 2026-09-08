-- Migration: fix intercity parcel final-delivery completion failing in production because
-- credit_rider_for_completed_order() has no bypass for protect_rider_financial_columns().
--
-- ROOT CAUSE (confirmed live against production, not assumed):
-- protect_rider_financial_columns() (20260730000000) guards riders.wallet_balance/
-- cod_pending_amount/etc. with `IF auth.role() <> 'service_role'` and NO escape hatch --
-- unlike its sibling protect_order_financial_columns() (20260724000004/20260724000005/
-- 20260725000002), which already has a proven `current_setting('app.bypass_financial_guard',
-- true)` bypass for exactly this situation. At the time 20260730000000 was written, every
-- writer of these columns (cashfree-webhook, verify-payment, apply_order_government_tax,
-- credit_rider_for_completed_order, initiate/fail/complete_withdrawal) really did only ever run
-- under service_role -- that migration's own header confirms this was checked and true then.
--
-- It stopped being true the same day, one migration later: 20260730000004
-- (intercity_parcel_delivery_settlement.sql) added complete_intercity_parcel_delivery(), a
-- SECURITY DEFINER RPC explicitly `GRANT EXECUTE ... TO authenticated` (called directly by the
-- rider's Flutter client, intercity_bookings_screen.dart's _completeParcel() ->
-- supabase.rpc('complete_intercity_parcel_delivery', ...), never through a service-role edge
-- function). SECURITY DEFINER does not change what auth.role() reports (it's a session-level JWT
-- claim, not something function execution context elevates -- the exact same fact 20260724000005
-- and 20260725000002 already document for the orders-table equivalent), so every call reaches
-- credit_rider_for_completed_order() as role 'authenticated', not 'service_role', and the guard
-- unconditionally raises. Confirmed live: the order safely rolls back to rider_at_drop (PL/pgSQL's
-- automatic exception-block rollback undoes the function's own earlier orders UPDATE too, so this
-- is a hard failure, not a corrupted partial state) -- but delivery can never complete.
--
-- The sibling local-ride/local-parcel/intercity-ride completion path (complete_order_and_settle,
-- 20260813000000/20260814000000) is and remains unaffected: it is `GRANT ... TO service_role`
-- only, called exclusively from update-order-status (the service-role edge function), so
-- auth.role() = 'service_role' there and the guard already passes trivially. This migration does
-- not touch complete_order_and_settle, update-order-status, or complete_intercity_parcel_delivery
-- at all.
--
-- FIX: apply the exact already-proven pattern (protect_order_financial_columns' own bypass, and
-- the same fix shape as 20260725000002_fix_fare_payment_financial_guard_bypass.sql), scoped to a
-- NEW, dedicated flag (app.bypass_rider_financial_guard) rather than reusing
-- app.bypass_financial_guard -- mirrors 20260730000008's own stated reasoning for why
-- app.bypass_order_state_guard is a separate flag from app.bypass_financial_guard: these guard
-- different tables/columns, and keeping each guard's bypass independent means a bug in one can
-- never accidentally widen another's bypass.
--
-- The bypass is set INSIDE credit_rider_for_completed_order() itself (transaction-local only,
-- third set_config arg `true`), not by each caller individually. This is deliberate:
-- credit_rider_for_completed_order() is GRANTed to service_role ONLY (20260724000003) -- it can
-- never be reached directly by an authenticated client, only from inside another already-running
-- SECURITY DEFINER function (complete_order_and_settle or complete_intercity_parcel_delivery),
-- both of which have already fully validated caller identity, order ownership, OTP, and the fare
-- amount before ever calling this function. Setting the bypass here, once, fixes every current AND
-- future legitimate caller uniformly, and is exactly the class of bug being fixed right now: a new
-- authenticated-callable settlement RPC (complete_intercity_parcel_delivery) was added after this
-- guard existed, and its author had no way to know a per-caller bypass was needed unless they
-- specifically knew to add it -- centralizing the bypass in the shared credit function removes that
-- failure mode entirely rather than just patching this one call site.
--
-- SECURITY: the financial-column protection itself is NOT weakened or disabled. A raw client PATCH
-- to riders.wallet_balance (or any other authenticated-role write not routed through this function)
-- is still rejected exactly as before -- app.bypass_rider_financial_guard is never set by anything
-- except this one function, is transaction-local (never leaks to another request/connection), and
-- credit_rider_for_completed_order() itself performs no authorization/amount decisions of its own
-- (the amount is computed and validated by its caller before this function is ever invoked).

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
        THEN
            RAISE EXCEPTION 'Direct modification of rider financial/subscription columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.credit_rider_for_completed_order(
    p_rider_id uuid,
    p_rider_earning numeric,
    p_is_direct_collection boolean,
    p_company_cod_share numeric
)
RETURNS void AS $$
BEGIN
    -- Transaction-local only (third arg `true`) -- never leaks to other statements/connections.
    -- Safe here specifically because this function is service_role-GRANTed only and computes no
    -- amounts of its own; see migration header for the full reasoning.
    PERFORM set_config('app.bypass_rider_financial_guard', 'true', true);

    UPDATE public.riders
    SET
        total_orders = COALESCE(total_orders, 0) + 1,
        total_completed_orders = COALESCE(total_completed_orders, 0) + 1,
        total_earnings = COALESCE(total_earnings, 0) + p_rider_earning,
        today_earnings = COALESCE(today_earnings, 0) + p_rider_earning,
        wallet_balance = COALESCE(wallet_balance, 0)
            + (CASE WHEN p_is_direct_collection THEN 0 ELSE p_rider_earning END),
        cod_pending_amount = COALESCE(cod_pending_amount, 0)
            + (CASE WHEN p_is_direct_collection THEN p_company_cod_share ELSE 0 END),
        updated_at = now()
    WHERE id = p_rider_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rider record not found for ID: %', p_rider_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- GRANT unchanged (CREATE OR REPLACE preserves existing grants for an unchanged signature) --
-- restated here only for clarity/auditability, not because it needs to be re-applied.
GRANT EXECUTE ON FUNCTION public.credit_rider_for_completed_order(uuid, numeric, boolean, numeric) TO service_role;
