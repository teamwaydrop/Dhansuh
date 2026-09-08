-- Migration: Lock down UPI verification (upi_verified/upi_verified_at) to server-only writes.
-- Date: 2026-07-25
--
-- CONTEXT: rider_payout_accounts still carries a broad "rider_update_own_payout_account" UPDATE
-- RLS policy (USING/WITH CHECK: auth.uid() = user_id, no column restriction), reintroduced by the
-- 20260716000010 baseline-recovery migration when the schema was restored from a prod dump.
-- 20260725000000/20260725000001 assumed no such policy existed ("rider_payout_accounts has no
-- UPDATE RLS policy at all ... every other write goes through create-rider-payout with the
-- service-role key") and relied on that assumption for upi_verified's integrity -- but the policy
-- is live on production, and a full grep of lib/ confirms no Flutter code path needs it: every
-- legitimate write already goes through create-rider-payout, verify-driver-upi, or
-- set_default_fare_payment_method, all of which run under the service role / SECURITY DEFINER and
-- never needed the authenticated role's own UPDATE grant. Left in place, it let any driver call
-- `supabase.from('rider_payout_accounts').update({upi_verified: true, upi_verified_at: ...})`
-- directly and self-verify without Cashfree ever confirming the VPA -- confirmed exploitable: it
-- is exactly how one real account ended up with upi_verified=true, upi_verified_at=null (a state
-- verify-driver-upi itself can never produce, since it always writes both fields together).

-- =====================================================================
-- 1. Remove the unused, unrestricted UPDATE policy.
-- =====================================================================
DROP POLICY IF EXISTS "rider_update_own_payout_account" ON public.rider_payout_accounts;

-- =====================================================================
-- 2. Defense in depth: even if a future change reopens some scoped UPDATE policy on this table,
-- this trigger still (a) blocks any non-service-role write to upi_verified/upi_verified_at, and
-- (b) forces re-verification the moment the VPA on file actually changes, regardless of caller
-- (including our own edge functions) -- a new VPA has never been checked with Cashfree, so no
-- code path, present or future, should be able to carry an old verification over to it.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_rider_upi_verification()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF auth.role() <> 'service_role' AND NEW.upi_verified IS TRUE THEN
            RAISE EXCEPTION 'upi_verified can only be set by the server after a successful Cashfree verification.';
        END IF;
        RETURN NEW;
    END IF;

    -- A changed VPA invalidates whatever verification existed, no matter who changed it.
    IF NEW.upi_vpa IS DISTINCT FROM OLD.upi_vpa THEN
        NEW.upi_verified := false;
        NEW.upi_verified_at := NULL;
    END IF;

    IF auth.role() <> 'service_role' THEN
        IF NEW.upi_verified IS DISTINCT FROM OLD.upi_verified
           OR NEW.upi_verified_at IS DISTINCT FROM OLD.upi_verified_at THEN
            RAISE EXCEPTION 'upi_verified can only be set by the server after a successful Cashfree verification.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS protect_rider_upi_verification_trigger ON public.rider_payout_accounts;
CREATE TRIGGER protect_rider_upi_verification_trigger
BEFORE INSERT OR UPDATE ON public.rider_payout_accounts
FOR EACH ROW
EXECUTE FUNCTION public.protect_rider_upi_verification();

-- =====================================================================
-- 3. One-time correction: upi_verified=true with upi_verified_at=null is a state
-- verify-driver-upi can never produce (it always writes both together) -- it only exists because
-- of the direct-update path closed above. Reset any row in that state back to unverified so the
-- driver must run the real verify-driver-upi flow (now actually deployed) before personal_upi can
-- be offered to passengers again.
-- =====================================================================
UPDATE public.rider_payout_accounts
SET upi_verified = false
WHERE upi_verified = true
  AND upi_verified_at IS NULL;
