-- Migration: Audit trail for UPI verification attempts.
-- Date: 2026-07-25
--
-- CONTEXT: verify-driver-upi's outcome (Cashfree's raw response, or the fact no response was
-- reachable) was previously only ever console.error'd -- ephemeral, not queryable after the fact.
-- That made a real production failure ("Feature not enabled" from Cashfree's Validate Payout API,
-- confirmed by their own docs to mean the merchant account lacks access to that capability)
-- impossible to prove from the database alone. These columns persist the last verification
-- attempt's raw outcome on every call (success or failure), regardless of caller, so any future
-- verification issue is traceable directly from rider_payout_accounts without needing edge log
-- access.
ALTER TABLE public.rider_payout_accounts
    ADD COLUMN IF NOT EXISTS upi_verification_last_checked_at timestamptz,
    ADD COLUMN IF NOT EXISTS upi_verification_last_response jsonb;
