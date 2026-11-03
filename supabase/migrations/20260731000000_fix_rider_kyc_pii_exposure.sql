-- =====================================================================
-- P0 FIX: rider_kyc RLS exposed full Aadhaar/PAN/DL numbers and KYC document
-- URLs of any "online" rider to every authenticated passenger.
-- =====================================================================
-- ROOT CAUSE: "Allow view own KYC or online rider KYC"
-- (20260531000003_fix_find_nearby_riders.sql:247-260) grants SELECT on the
-- FULL rider_kyc row -- including aadhaar_number, pan_number,
-- driving_license_number, and every document image URL column -- to any
-- authenticated user whenever the target rider's account_status = 'online'.
-- Confirmed still live: no later migration redefines this policy.
--
-- LEGITIMATE USE PRESERVED: two passenger-facing screens
-- (intercity_searching_screen.dart, intercity_matching_service.dart) query
-- rider_kyc for OTHER riders' full_name/vehicle_type/vehicle_number/
-- rider_image/kyc_status to render matching cards -- never aadhaar/pan/dl/
-- document columns. This migration replaces the raw-table policy with an
-- owner-only (+ admin/support) policy, and adds a narrow view exposing only
-- those five non-sensitive columns, gated by the SAME account_status='online'
-- condition the original (insecure) policy used -- so this app's own current
-- behavior for that feature is unchanged, while ID numbers/documents are no
-- longer reachable by anyone but the row's owner (or admin/support staff).
--
-- Storage (rider_kyc document bucket): not touched here -- no migration in
-- this repo ever created that bucket, so its actual Dashboard-configured
-- public/private setting cannot be verified from code and must not be
-- guessed at. Flagged separately for manual Dashboard verification.
-- =====================================================================

DROP POLICY IF EXISTS "Allow view own KYC or online rider KYC" ON public.rider_kyc;

CREATE POLICY "Riders view own KYC or admin support view any"
ON public.rider_kyc
FOR SELECT
TO authenticated
USING (
    auth.uid() = user_id
    OR
    EXISTS (
        SELECT 1 FROM public.users u
        WHERE u.id = auth.uid() AND (u.role = 'admin' OR u.role = 'support')
    )
);

-- Safe, narrow subset for passenger-facing "online rider" lookups. Views in
-- Postgres execute with the privileges of the view owner (the migration
-- role, not `authenticated`) unless the underlying table has FORCE ROW LEVEL
-- SECURITY set -- confirmed rider_kyc does not -- so this correctly bypasses
-- the now-restrictive owner-only policy above for exactly these 5 columns,
-- with the row-visibility condition re-implemented explicitly rather than
-- inherited.
CREATE OR REPLACE VIEW public.rider_kyc_public AS
SELECT
    k.user_id,
    k.full_name,
    k.vehicle_type,
    k.vehicle_number,
    k.rider_image,
    k.kyc_status
FROM public.rider_kyc k
JOIN public.riders r ON r.user_id = k.user_id
WHERE r.account_status = 'online';

GRANT SELECT ON public.rider_kyc_public TO authenticated;
