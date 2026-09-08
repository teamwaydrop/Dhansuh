-- =====================================================================
-- FIX (proven root cause, live-tested): initiate_withdrawal() generated its
-- own transfer_id as 'WDT' || <uuid>. That exact value was sent to Cashfree
-- and Cashfree registered the transfer under it (confirmed live: Cashfree's
-- own response echoed back "transfer_id": "WDT86107ad3ff664522a6dccb517c7ca261").
-- But rider_withdrawals has a BEFORE INSERT trigger
-- (trg_populate_transfer_id -> trg_rider_withdrawals_transfer_id()) that
-- silently overwrites transfer_id with a freshly generated 'WDPY'-prefixed
-- code whenever the incoming value doesn't already match 'WDPY%' -- which a
-- 'WDT...' value never does. The row actually persisted under a DIFFERENT
-- id ("WDPYRRMCS5" in the live test) than the one Cashfree has on file.
-- Reconciliation (create-rider-withdrawal's GET/sync path, invoked whenever
-- the rider opens Earnings/Payouts) then queries Cashfree using the stored
-- (wrong) transfer_id, gets 404, and after 5 minutes calls fail_withdrawal()
-- -- which refunds the wallet -- while the real transfer keeps processing on
-- Cashfree's side under the id actually sent. Confirmed live: this is a
-- genuine double-dip risk (wallet refunded AND the real bank transfer still
-- completes).
--
-- FIX: initiate_withdrawal() now generates the transfer_id via the SAME
-- canonical public.generate_unique_transfer_id() the trigger itself uses
-- (the 'WDPY' + 6 random alphanumeric chars format), instead of its own
-- ad-hoc 'WDT' + uuid format. Since the value already matches 'WDPY%' by
-- construction, the BEFORE INSERT trigger's overwrite condition is never
-- true for this path -- NEW.transfer_id passes through completely
-- unmodified. The RPC still returns this same value to
-- create-rider-withdrawal, which is what gets sent to Cashfree -- so
-- generated, stored, sent-to-Cashfree, and used-for-reconciliation are now
-- guaranteed to be the exact same string, by construction, for the entire
-- lifecycle of every withdrawal.
--
-- Nothing else changes: same locking order, same balance check, same
-- beneficiary-status gate (from the prior fix), same insert shape, same
-- return shape. The trigger itself is untouched -- it remains as a
-- defensive fallback for any other/future insert path that doesn't already
-- supply a correctly-formatted transfer_id.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.initiate_withdrawal(p_amount numeric, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rider_id uuid;
    v_wallet_balance numeric;
    v_payout_account_id uuid;
    v_payout_status public.cashfree_beneficiary_status_enum;
    v_transfer_id text;
    v_withdrawal_id uuid;
    v_beneficiary_id text;
    v_payout_method public.payout_method_enum;
    v_upi_vpa text;
BEGIN
    -- 1. Validation for withdrawal amount
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Invalid withdrawal amount'
        );
    END IF;

    -- 2. Fetch rider and lock row to prevent race conditions on balance updates
    SELECT id, wallet_balance INTO v_rider_id, v_wallet_balance
    FROM public.riders
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Rider profile not found');
    END IF;

    -- 3. Fetch payout account details (limit to 1 account to prevent multi-row return database exception)
    SELECT id, cashfree_beneficiary_status, beneficiary_id, payout_method, upi_vpa
    INTO v_payout_account_id, v_payout_status, v_beneficiary_id, v_payout_method, v_upi_vpa
    FROM public.rider_payout_accounts
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_payout_account_id IS NULL OR v_beneficiary_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Payout account beneficiary ID not found');
    END IF;

    -- Beneficiary must actually be confirmed active with Cashfree -- a
    -- 'pending'/'failed'/'disabled' status means no real beneficiary exists on
    -- Cashfree's side for this beneficiary_id, and a Transfer against it will fail.
    IF v_payout_status IS DISTINCT FROM 'active'::public.cashfree_beneficiary_status_enum THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Your payout details are not yet verified with Cashfree. Please open Payment Settings and re-save your bank/UPI details, then try again.'
        );
    END IF;

    -- 4. Check wallet balance
    IF v_wallet_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'Insufficient wallet balance');
    END IF;

    -- 5. Generate the transfer_id via the same canonical generator the
    -- rider_withdrawals BEFORE INSERT trigger itself uses, so the trigger's
    -- 'already WDPY-formatted' check passes and never overwrites this value --
    -- this is the exact id sent to Cashfree below (in create-rider-withdrawal)
    -- and the exact id that ends up stored, guaranteeing they match.
    v_transfer_id := public.generate_unique_transfer_id();

    -- 6. Deduct wallet balance (rider row is already locked)
    UPDATE public.riders
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = v_rider_id;

    -- 7. Insert pending withdrawal (logs trigger automatically)
    INSERT INTO public.rider_withdrawals (
        rider_id,
        user_id,
        amount,
        transfer_id,
        status
    ) VALUES (
        v_rider_id,
        p_user_id,
        p_amount,
        v_transfer_id,
        'pending'::public.rider_withdrawal_status_enum
    ) RETURNING id INTO v_withdrawal_id;

    RETURN jsonb_build_object(
        'success', true,
        'rider_id', v_rider_id,
        'withdrawal_id', v_withdrawal_id,
        'transfer_id', v_transfer_id,
        'beneficiary_id', v_beneficiary_id,
        'payout_method', v_payout_method,
        'upi_vpa', v_upi_vpa
    );
END;
$function$;
