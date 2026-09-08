-- =====================================================================
-- FIX (Phase 3 Financial Revenue Audit): Withdraw fails with Cashfree's
-- "beneficiary_not_found" on the large majority of attempts.
-- =====================================================================
-- ROOT CAUSE, confirmed against live production data:
--   1. initiate_withdrawal() fetches rider_payout_accounts.cashfree_beneficiary_status
--      into a variable but never checks it -- it only verifies beneficiary_id IS NOT
--      NULL, which is architecturally always true (generate_rider_beneficiary_id()
--      auto-fills it on row creation regardless of whether Cashfree ever actually
--      registered it). So a 'failed'/'pending'/'disabled' beneficiary is handed
--      straight to the Cashfree Transfer call.
--   2. Compounding this: create-rider-payout/index.ts (Edge Function, fixed in the
--      same deploy as this migration) was misclassifying Cashfree's
--      "conflict_with_existing_beneficiary" response (a DIFFERENT beneficiary_id
--      already owns that bank account -- the new one was never created) as a
--      successful registration, writing cashfree_beneficiary_status='active' for a
--      beneficiary_id that was never actually registered with Cashfree at all.
--      Confirmed live: the two riders actively retrying withdrawals as of this
--      migration (2026-08-06) both have this exact contradiction in
--      rider_payout_accounts.cashfree_beneficiary_response.
--
-- FIX:
--   1. initiate_withdrawal() now requires cashfree_beneficiary_status = 'active'
--      before authorizing a withdrawal, with a clear rejection message otherwise.
--   2. Data correction: the two rows currently mismarked 'active' by bug #2 above
--      are reset to 'failed' so they're correctly blocked by fix #1 until the rider
--      re-saves their payout details successfully (Edge Function fix, deployed
--      alongside this migration, stops this misclassification from recurring).
-- No other behavior of initiate_withdrawal changes -- same locking, same wallet
-- deduction, same withdrawal-row insert, same return shape.
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

    -- NEW CHECK: the beneficiary must actually be confirmed active with Cashfree --
    -- a 'pending'/'failed'/'disabled' status means no real beneficiary exists on
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

    -- 5. Generate unique transfer_id
    v_transfer_id := 'WDT' || REPLACE(gen_random_uuid()::text, '-', '');

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

-- =====================================================================
-- Data correction: the 2 rows currently mismarked 'active' due to the
-- create-rider-payout conflict-misclassification bug. Precisely targeted --
-- only rows whose OWN stored Cashfree response is the exact conflict error,
-- not a blanket reset of every 'active' row.
-- =====================================================================
UPDATE public.rider_payout_accounts
SET cashfree_beneficiary_status = 'failed'::public.cashfree_beneficiary_status_enum,
    updated_at = now()
WHERE cashfree_beneficiary_status = 'active'::public.cashfree_beneficiary_status_enum
  AND cashfree_beneficiary_response->>'code' = 'conflict_with_existing_beneficiary';
