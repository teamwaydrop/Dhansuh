-- =====================================================================
-- DATA CORRECTION (proven, not guessed): create-rider-withdrawal's sync
-- path called GET {baseUrl}/transfers/{transfer_id} (a path-segment URL).
-- Cashfree's actual Payouts V2 "Get Transfer Status" endpoint is
-- GET {baseUrl}/transfers?transfer_id={transfer_id} (query parameter).
-- The malformed URL caused Cashfree to respond 200 OK with an auth-layer
-- error body {"message":"Token is not valid","status":"ERROR","subCode":"403"}
-- instead of a real transfer status. The sync code read status:"ERROR" as a
-- genuine transfer failure and called fail_withdrawal(), refunding the
-- wallet for withdrawals that had actually already succeeded at Cashfree.
--
-- The URL bug itself is already fixed in create-rider-withdrawal/index.ts.
-- This migration corrects the 3 historical rows for rider
-- 291fe5ee-91f6-4228-a475-f5a493c6217d that were wrongly marked 'failed'
-- and wrongly refunded, verified against Cashfree's real, authoritative
-- transfer records (queried directly via the fixed endpoint, using the
-- transfer_id or, where the row predates a separate earlier transfer_id
-- fix, the cf_transfer_id):
--
--   f9af3c8e-9c67-49f4-9346-c6a80d41be77  ₹1  cf_transfer_id 2376470686
--     Cashfree: SUCCESS / COMPLETED, UTR 621819529139
--   7608f5c7-0ad8-4a9f-8622-40a72e12ade2  ₹1  transfer_id WDPYK4PHYL
--     Cashfree: SUCCESS / COMPLETED, UTR 621820576299
--   19bdbf38-5937-4cb7-8773-f951573afc65  ₹2  transfer_id WDPYB4QVRO
--     Cashfree: SUCCESS / COMPLETED, UTR 621820586578
--
-- A 4th row (1d953db3-070a-4d09-a910-02aab61070a6, ₹7 UPI, WDPYK5BZA4) was
-- also checked and Cashfree confirms it is genuinely REJECTED
-- (BENE_INVALID_MODE -- UPI mode invalid for that beneficiary, unrelated to
-- the URL bug). That row's 'failed' status and refund are correct and are
-- NOT touched by this migration, other than replacing its stored
-- cashfree_response with the real rejection reason for audit accuracy.
--
-- For the 3 SUCCESS rows: status is corrected to 'success', the real
-- Cashfree response is stored in place of the misleading auth-error
-- response, and the wallet refund that should never have happened is
-- reversed (wallet_balance -= amount, exactly undoing fail_withdrawal's
-- earlier `wallet_balance = wallet_balance + v_amount`). Total reversal:
-- ₹1 + ₹1 + ₹2 = ₹4.
-- =====================================================================

BEGIN;

-- Lock the rider row first (same lock ordering used throughout the
-- withdrawal RPCs) to avoid racing a concurrent wallet-affecting operation.
DO $$
DECLARE
    v_rider_id uuid := '291fe5ee-91f6-4228-a475-f5a493c6217d';
BEGIN
    PERFORM 1 FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Row 1: ₹1, cf_transfer_id 2376470686 -- confirmed SUCCESS at Cashfree
    UPDATE public.rider_withdrawals
    SET status = 'success'::public.rider_withdrawal_status_enum,
        cashfree_response = '{"transfer_id":"WDT86107ad3ff664522a6dccb517c7ca261","cf_transfer_id":"2376470686","status":"SUCCESS","status_code":"COMPLETED","status_description":"The transfer has been initiated via the partner bank successfully, hence your account is debited and the request is successfuly processed by the beneficiary bank and has been credited to the end beneficiary.","transfer_amount":1,"transfer_mode":"imps","transfer_utr":"621819529139","added_on":"2026-08-06T19:53:21","updated_on":"2026-08-06T19:53:23","_correction_note":"Original row wrongly marked failed by the /transfers/{id} URL bug; corrected after direct Cashfree verification."}'::jsonb
    WHERE id = 'f9af3c8e-9c67-49f4-9346-c6a80d41be77'
      AND rider_id = v_rider_id
      AND status = 'failed'::public.rider_withdrawal_status_enum;

    IF FOUND THEN
        UPDATE public.riders SET wallet_balance = wallet_balance - 1.00 WHERE id = v_rider_id;
    END IF;

    -- Row 2: ₹1, transfer_id WDPYK4PHYL -- confirmed SUCCESS at Cashfree
    UPDATE public.rider_withdrawals
    SET status = 'success'::public.rider_withdrawal_status_enum,
        cashfree_response = '{"transfer_id":"WDPYK4PHYL","cf_transfer_id":"2376505637","status":"SUCCESS","status_code":"COMPLETED","status_description":"The transfer has been initiated via the partner bank successfully, hence your account is debited and the request is successfuly processed by the beneficiary bank and has been credited to the end beneficiary.","transfer_amount":1,"transfer_mode":"imps","transfer_utr":"621820576299","added_on":"2026-08-06T20:30:10","updated_on":"2026-08-06T20:30:25","_correction_note":"Original row wrongly marked failed by the /transfers/{id} URL bug; corrected after direct Cashfree verification."}'::jsonb
    WHERE id = '7608f5c7-0ad8-4a9f-8622-40a72e12ade2'
      AND rider_id = v_rider_id
      AND status = 'failed'::public.rider_withdrawal_status_enum;

    IF FOUND THEN
        UPDATE public.riders SET wallet_balance = wallet_balance - 1.00 WHERE id = v_rider_id;
    END IF;

    -- Row 3: ₹2, transfer_id WDPYB4QVRO -- confirmed SUCCESS at Cashfree
    UPDATE public.rider_withdrawals
    SET status = 'success'::public.rider_withdrawal_status_enum,
        cashfree_response = '{"transfer_id":"WDPYB4QVRO","cf_transfer_id":"2376512696","status":"SUCCESS","status_code":"COMPLETED","status_description":"The transfer has been initiated via the partner bank successfully, hence your account is debited and the request is successfuly processed by the beneficiary bank and has been credited to the end beneficiary.","transfer_amount":2,"transfer_mode":"imps","transfer_utr":"621820586578","added_on":"2026-08-06T20:38:53","updated_on":"2026-08-06T20:38:55","_correction_note":"Original row wrongly marked failed by the /transfers/{id} URL bug; corrected after direct Cashfree verification."}'::jsonb
    WHERE id = '19bdbf38-5937-4cb7-8773-f951573afc65'
      AND rider_id = v_rider_id
      AND status = 'failed'::public.rider_withdrawal_status_enum;

    IF FOUND THEN
        UPDATE public.riders SET wallet_balance = wallet_balance - 2.00 WHERE id = v_rider_id;
    END IF;

    -- Row 4: ₹7 UPI, transfer_id WDPYK5BZA4 -- confirmed REJECTED at Cashfree
    -- (BENE_INVALID_MODE, unrelated to the URL bug). Status and refund are
    -- correct and untouched; only the stored response is corrected to the
    -- real rejection reason for audit accuracy.
    UPDATE public.rider_withdrawals
    SET cashfree_response = '{"transfer_id":"WDPYK5BZA4","cf_transfer_id":"2376512807","status":"REJECTED","status_code":"BENE_INVALID_MODE","status_description":"The transfer has been rejected because the mode is invalid for the given beneficiary. After correcting the mode and beneficiary, You can reinitiate the transfer via Cashfree so that the transfer can be reattempted again by Cashfree with the partner bank(s).","transfer_amount":7,"transfer_mode":"upi","added_on":"2026-08-06T20:39:00","updated_on":"2026-08-06T20:39:00","_correction_note":"Genuinely rejected by Cashfree; refund is correct. Only this response payload was corrected from the misleading /transfers/{id} URL-bug auth error to the real rejection reason."}'::jsonb
    WHERE id = '1d953db3-070a-4d09-a910-02aab61070a6'
      AND rider_id = v_rider_id
      AND status = 'failed'::public.rider_withdrawal_status_enum;
END $$;

COMMIT;
