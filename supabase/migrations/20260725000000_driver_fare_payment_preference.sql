-- Migration: Driver-preference fare collection (personal UPI default, Cashfree fallback).
-- Date: 2026-07-25
--
-- CONTEXT: passenger fares currently always collect via Cashfree gateway checkout
-- (GatewayPaymentPanel / payment_mode = 'online'), added after direct-to-driver upi://pay P2P
-- pushes proved unreliable in production (banks/NPCI flag a personal VPA receiving many small
-- payments from rotating strangers, regardless of which UPI app sends it). Business now wants
-- personal UPI as the driver's DEFAULT collection method (avoids Cashfree payout fees), with
-- Cashfree kept as an always-available fallback (manual, since a raw UPI intent has no result
-- callback -- we can never know in-app that a push was security-declined, only that the app
-- opened). This migration adds the schema for that: which method each driver prefers, whether
-- their VPA has been verified, an audit trail per order for dispute resolution, and a real
-- disputes table for the admin panel's Pending/Paid/Disputed status.

-- =====================================================================
-- 1. FARE PAYMENT METHOD ENUM
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'fare_payment_method_enum') THEN
        CREATE TYPE public.fare_payment_method_enum AS ENUM ('personal_upi', 'cashfree');
    END IF;
END$$;

-- =====================================================================
-- 2. rider_payout_accounts: driver's fare-collection preference + UPI verification.
-- Reuses the existing upi_vpa column (same VPA already used for Cashfree Payouts withdrawal) --
-- this is a new PURPOSE for that value (passenger pays it directly), not a new VPA to collect.
-- No QR-image column: the QR is generated client-side on demand from upi_vpa (qr_flutter), so
-- there is nothing to store or keep in sync -- one fewer place this could drift from the VPA on
-- file, and no upload/storage bucket to maintain.
-- Neither of these two columns is in check_payout_update_limit()'s watched-column list, so
-- changing them does not count against the existing 2-updates/7-days sensitive-field limit --
-- intentional: this is a preference toggle + a system-set verification flag, not a payout-detail
-- change like account/IFSC/VPA itself (which remain rate-limited exactly as before).
-- =====================================================================
ALTER TABLE public.rider_payout_accounts
    ADD COLUMN IF NOT EXISTS default_fare_payment_method public.fare_payment_method_enum NOT NULL DEFAULT 'personal_upi',
    ADD COLUMN IF NOT EXISTS upi_verified boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS upi_verified_at timestamptz;

-- =====================================================================
-- 3. orders: per-order fare-payment audit trail (which method was actually used, when the
-- passenger was given a real chance to pay, when it was confirmed, and optional dispute evidence).
-- `fare_payment_attempted_at` generalizes the old upi_payment_prompted_at idea to both methods --
-- same protection: a driver can't self-report receipt before the passenger was actually shown a
-- real payment attempt.
-- =====================================================================
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS fare_payment_method public.fare_payment_method_enum,
    ADD COLUMN IF NOT EXISTS fare_payment_attempted_at timestamptz,
    ADD COLUMN IF NOT EXISTS fare_paid_at timestamptz,
    ADD COLUMN IF NOT EXISTS fare_payment_reference text,
    ADD COLUMN IF NOT EXISTS fare_payment_screenshot_url text;

-- =====================================================================
-- 4. Extend the existing financial-columns guard (20260724000004) to also cover payment_status
-- and fare_payment_method -- these two together decide whether the driver's wallet gets credited
-- (personal_upi: no, money already reached the driver directly, same as cash; cashfree: yes,
-- platform is holding the fare). Same defense-in-depth rationale as the columns already guarded
-- there: our edge functions (service_role) are the only legitimate writer of either.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role' THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
           OR NEW.payment_status IS DISTINCT FROM OLD.payment_status
           OR NEW.fare_payment_method IS DISTINCT FROM OLD.fare_payment_method
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 5. payment_disputes: real dispute-resolution table (not an overload of payment_status_enum,
-- which stays a simple settlement flag) -- lets the admin panel show a derived Pending/Paid/
-- Disputed status (Disputed = an 'open'/'investigating' row exists) and gives disputes their own
-- resolution workflow/audit trail. RLS follows the same inline admin-role EXISTS pattern used
-- throughout this schema (no is_admin() helper exists anywhere else; not introducing one here).
-- =====================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'dispute_status_enum') THEN
        CREATE TYPE public.dispute_status_enum AS ENUM ('open', 'investigating', 'resolved_paid', 'resolved_unpaid');
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.payment_disputes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    raised_by uuid NOT NULL REFERENCES public.users(id),
    raised_role text NOT NULL CHECK (raised_role IN ('passenger', 'driver')),
    reason text NOT NULL,
    status public.dispute_status_enum NOT NULL DEFAULT 'open',
    evidence_screenshot_url text,
    admin_notes text,
    resolved_by uuid REFERENCES public.users(id),
    resolved_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payment_disputes_order_id ON public.payment_disputes (order_id);
CREATE INDEX IF NOT EXISTS idx_payment_disputes_status ON public.payment_disputes (status);

ALTER TABLE public.payment_disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Order participants can view their own disputes" ON public.payment_disputes;
CREATE POLICY "Order participants can view their own disputes"
ON public.payment_disputes
FOR SELECT
TO authenticated
USING (
    raised_by = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = payment_disputes.order_id
          AND (o.user_id = auth.uid() OR o.rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid()))
    )
    OR EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
);

DROP POLICY IF EXISTS "Order participants can raise a dispute" ON public.payment_disputes;
CREATE POLICY "Order participants can raise a dispute"
ON public.payment_disputes
FOR INSERT
TO authenticated
WITH CHECK (
    raised_by = auth.uid()
    AND EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = payment_disputes.order_id
          AND (o.user_id = auth.uid() OR o.rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid()))
    )
);

DROP POLICY IF EXISTS "Admins can resolve disputes" ON public.payment_disputes;
CREATE POLICY "Admins can resolve disputes"
ON public.payment_disputes
FOR UPDATE
TO authenticated
USING (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin'))
WITH CHECK (EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin'));

-- =====================================================================
-- 6. Storage bucket for dispute evidence screenshots only. No QR bucket -- the QR is generated
-- client-side on demand from upi_vpa (qr_flutter), never stored as an image. Evidence screenshots
-- can contain a passenger's UPI app account details, so this bucket is kept private, readable
-- only by the order's own participants + admin, via signed URLs.
-- =====================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('dispute_evidence', 'dispute_evidence', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "Authenticated users can upload dispute evidence" ON storage.objects;
CREATE POLICY "Authenticated users can upload dispute evidence"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'dispute_evidence');

DROP POLICY IF EXISTS "Owners and admins can view dispute evidence" ON storage.objects;
CREATE POLICY "Owners and admins can view dispute evidence"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'dispute_evidence'
    AND (
        auth.uid()::text = owner_id
        OR EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
    )
);
