-- Migration: Driver-uploaded Personal UPI QR (replaces client-generated QR-from-VPA).
-- Date: 2026-07-25
--
-- CONTEXT: the previous personal_upi flow rendered a QR client-side from the driver's typed VPA
-- (qr_flutter, upi://pay?pa=...). Real devices have shown this generated-QR + raw upi:// intent
-- approach is unreliable (GPay/PhonePe security rejections on repeated small P2P pushes). The
-- product direction is now: the driver uploads their OWN real receive-money QR image (captured
-- from GPay/PhonePe/Paytm/bank app), and that exact image is shown to passengers -- never
-- synthesized. The stored VPA text is kept only for display/reference and for the passenger's
-- optional "Pay via UPI Apps" convenience deep link (a separate, non-authoritative path).

-- =====================================================================
-- 1. Storage locations for the uploaded QR image + when it was last uploaded.
-- =====================================================================
ALTER TABLE public.rider_payout_accounts
    ADD COLUMN IF NOT EXISTS personal_qr_path text,
    ADD COLUMN IF NOT EXISTS personal_qr_uploaded_at timestamptz;

-- =====================================================================
-- 2. set_personal_qr_path(path): the only way personal_qr_path can ever be written. Same pattern
-- as set_default_fare_payment_method -- rider_payout_accounts has no open client UPDATE policy
-- (locked down in 20260725000003), so this narrow SECURITY DEFINER function is the sole write
-- path. Validates the path was actually uploaded under the caller's own rider_id folder
-- (driver_personal_qr/{rider_id}/...) so a driver can never point their record at another
-- driver's uploaded object.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.set_personal_qr_path(p_path text)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_updated public.rider_payout_accounts;
BEGIN
    SELECT id INTO v_rider_id FROM public.riders WHERE user_id = auth.uid();

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Rider profile not found.');
    END IF;

    IF p_path IS NULL OR p_path NOT LIKE (v_rider_id::text || '/%') THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid QR upload path.');
    END IF;

    UPDATE public.rider_payout_accounts
    SET personal_qr_path = p_path,
        personal_qr_uploaded_at = now(),
        updated_at = now()
    WHERE user_id = auth.uid()
    RETURNING * INTO v_updated;

    IF v_updated.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Complete your payout details before uploading a QR.');
    END IF;

    RETURN jsonb_build_object('success', true, 'personal_qr_path', v_updated.personal_qr_path);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.set_personal_qr_path(text) TO authenticated;

-- =====================================================================
-- 3. get_order_driver_fare_payment_info: add personal_qr_path so the passenger's tracking screen
-- (and the driver's own payment_pending screen) can resolve whether a real uploaded QR exists.
-- Everything else identical to the 20260725000005 definition.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_order_driver_fare_payment_info(p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'upi_vpa', rpa.upi_vpa,
        'upi_self_certified', rpa.upi_self_certified,
        'beneficiary_name', rpa.beneficiary_name,
        'personal_qr_path', rpa.personal_qr_path
    ) INTO v_result
    FROM public.orders o
    JOIN public.rider_payout_accounts rpa ON rpa.rider_id = o.rider_id
    WHERE o.id = p_order_id
      AND o.user_id = auth.uid()
      AND o.rider_id IS NOT NULL;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- =====================================================================
-- 4. Storage bucket for the uploaded QR image. Private -- readable only by the owning driver, the
-- passenger on an order currently assigned to that driver, and admins. Never public: unlike
-- parcel_images, a personal UPI QR should not be enumerable/guessable by unrelated users.
-- =====================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('driver_personal_qr', 'driver_personal_qr', false)
ON CONFLICT (id) DO UPDATE SET public = false;

DROP POLICY IF EXISTS "Drivers can upload their own personal QR" ON storage.objects;
CREATE POLICY "Drivers can upload their own personal QR"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = auth.uid()
          AND (storage.foldername(name))[1] = r.id::text
    )
);

DROP POLICY IF EXISTS "Drivers can replace their own personal QR" ON storage.objects;
CREATE POLICY "Drivers can replace their own personal QR"
ON storage.objects FOR UPDATE
TO authenticated
USING (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = auth.uid()
          AND (storage.foldername(name))[1] = r.id::text
    )
)
WITH CHECK (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = auth.uid()
          AND (storage.foldername(name))[1] = r.id::text
    )
);

DROP POLICY IF EXISTS "Drivers can delete their own personal QR" ON storage.objects;
CREATE POLICY "Drivers can delete their own personal QR"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = auth.uid()
          AND (storage.foldername(name))[1] = r.id::text
    )
);

DROP POLICY IF EXISTS "Drivers can view their own personal QR" ON storage.objects;
CREATE POLICY "Drivers can view their own personal QR"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.user_id = auth.uid()
          AND (storage.foldername(name))[1] = r.id::text
    )
);

-- Ride participants (the passenger currently on a trip with this driver) may view the driver's QR
-- while the trip is live through to payment settlement -- this is exactly the window the passenger
-- legitimately needs to see it (e.g. if the app ever displays it passenger-side), and no longer.
DROP POLICY IF EXISTS "Order participants can view assigned driver personal QR" ON storage.objects;
CREATE POLICY "Order participants can view assigned driver personal QR"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.user_id = auth.uid()
          AND o.rider_id::text = (storage.foldername(name))[1]
          AND o.order_status IN ('accepted', 'rider_arrived', 'ongoing', 'picked_up', 'rider_at_drop', 'payment_pending')
    )
);

DROP POLICY IF EXISTS "Admins can view all personal QR" ON storage.objects;
CREATE POLICY "Admins can view all personal QR"
ON storage.objects FOR SELECT
TO authenticated
USING (
    bucket_id = 'driver_personal_qr'
    AND EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND role = 'admin')
);
