-- Migration: Populate the wallet_transactions immutable ledger from withdrawal functions.
-- Date: 2026-07-16
--
-- initiate_withdrawal, fail_withdrawal, and complete_withdrawal mutate riders.wallet_balance
-- directly but never write to wallet_transactions, so audit_rider_wallets() (which reconciles
-- wallet_balance against SUM(wallet_transactions.amount)) permanently flags a false discrepancy
-- for every rider who has ever withdrawn funds. This migration re-adds a matching signed ledger
-- entry alongside each wallet_balance mutation, with no other change to withdrawal behavior.
--
-- initiate_withdrawal is redefined from its latest version (20260611000002_prefixed_alphanumeric_codes.sql),
-- which uses generate_unique_transfer_id(). fail_withdrawal and complete_withdrawal are redefined
-- from their only version (20260530000001_rider_withdrawals.sql).

-- 1. initiate_withdrawal: record a debit ledger entry for the wallet deduction.
CREATE OR REPLACE FUNCTION public.initiate_withdrawal(p_amount numeric, p_user_id uuid)
RETURNS jsonb AS $$
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

    -- 4. Check wallet balance
    IF v_wallet_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'Insufficient wallet balance');
    END IF;

    -- 5. Generate unique transfer_id using WDPY prefix
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

    -- 8. Record the ledger entry for this wallet debit
    INSERT INTO public.wallet_transactions (
        rider_id,
        amount,
        type,
        reference_id,
        reference_type,
        description
    ) VALUES (
        v_rider_id,
        -p_amount,
        'debit',
        v_withdrawal_id,
        'withdrawal',
        'Withdrawal requested, debited from wallet'
    );

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. fail_withdrawal: record a credit ledger entry for the wallet refund.
CREATE OR REPLACE FUNCTION public.fail_withdrawal(p_withdrawal_id uuid, p_error_response jsonb)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_status public.rider_withdrawal_status_enum;
BEGIN
    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Only allow failing from non-finalized states (pending or processing)
    IF v_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_status::text || ' state');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = 'failed'::public.rider_withdrawal_status_enum,
        cashfree_response = p_error_response
    WHERE id = p_withdrawal_id;

    -- Lock rider row for update
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Refund rider's wallet balance
    UPDATE public.riders
    SET wallet_balance = wallet_balance + v_amount
    WHERE id = v_rider_id;

    -- Record the ledger entry for this wallet refund
    INSERT INTO public.wallet_transactions (
        rider_id,
        amount,
        type,
        reference_id,
        reference_type,
        description
    ) VALUES (
        v_rider_id,
        v_amount,
        'credit',
        p_withdrawal_id,
        'withdrawal',
        'Withdrawal failed, refunded to wallet'
    );

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. complete_withdrawal: record a credit ledger entry when a withdrawal resolves to failed.
CREATE OR REPLACE FUNCTION public.complete_withdrawal(
    p_withdrawal_id uuid,
    p_cashfree_ref_id text,
    p_status text,
    p_response jsonb
)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_current_status public.rider_withdrawal_status_enum;
    v_new_status public.rider_withdrawal_status_enum;
BEGIN
    -- Safely cast input status text to enum
    BEGIN
        v_new_status := p_status::public.rider_withdrawal_status_enum;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid status to complete withdrawal');
    END;

    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_current_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Check if already finalized (success or failed)
    IF v_current_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_current_status::text || ' state');
    END IF;

    -- Prevent invalid transition from processing back to pending
    IF v_current_status = 'processing'::public.rider_withdrawal_status_enum AND v_new_status = 'pending'::public.rider_withdrawal_status_enum THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cannot transition from processing back to pending');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = v_new_status,
        cashfree_reference_id = p_cashfree_ref_id,
        cashfree_response = p_response
    WHERE id = p_withdrawal_id;

    -- Refund rider's wallet balance if status resolved to failed
    IF v_new_status = 'failed'::public.rider_withdrawal_status_enum THEN
        -- Lock rider row for update
        PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

        UPDATE public.riders
        SET wallet_balance = wallet_balance + v_amount
        WHERE id = v_rider_id;

        -- Record the ledger entry for this wallet refund
        INSERT INTO public.wallet_transactions (
            rider_id,
            amount,
            type,
            reference_id,
            reference_type,
            description
        ) VALUES (
            v_rider_id,
            v_amount,
            'credit',
            p_withdrawal_id,
            'withdrawal',
            'Withdrawal failed, refunded to wallet'
        );
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
