-- =====================================================================
-- FIX: regression introduced by 20260731000000_fix_rider_kyc_pii_exposure.sql
-- =====================================================================
-- That migration correctly locked down direct SELECT on public.rider_kyc to
-- owner (+ admin/support) only, and added public.rider_kyc_public (a narrow,
-- 5-column, online-riders-only view) so the passenger-facing "nearby driver"
-- matching screens that already queried the view directly kept working.
--
-- Two gaps in that migration's audit, found while investigating a production
-- startup/KYC regression report:
--
-- 1) PostgREST embeds (`riders.select('rider_kyc!riders_kyc_id_fkey(...)')`)
--    resolve through the actual FK-linked BASE TABLE, never through a view --
--    rider_kyc_public was simply unreachable by that syntax. Every call site
--    using that embed to read a DIFFERENT rider's (not the caller's own) KYC
--    row started silently getting a null nested object once the owner-only
--    policy went live (RLS on an embedded resource fails closed, not with an
--    error -- the parent row just comes back with that field null):
--      - RealtimeOrderController._fetchRider -- assigned driver's name/photo
--        on the passenger's live order-tracking screen
--      - ActivityTab.loadOrders -- past driver's name/photo/vehicle in ride
--        history (needs riders who have since gone offline -- outside
--        rider_kyc_public's online-only condition, see gap 2)
--      - ride_location_screen.dart / parcel_booking_screen.dart /
--        intercity_booking_screen.dart _fetchNearbyRiders -- nearby-driver
--        vehicle_type silently defaulted to 'bike' for every online rider,
--        corrupting vehicle-type filtering/markers on the booking map
--    Fixed by updating those call sites (same deploy) to query
--    rider_kyc_public via a second explicit request instead of the embed.
--
-- 2) rider_kyc_public's visibility condition (`account_status = 'online'`)
--    cannot serve order-history: a past order's rider is very often offline
--    by the time the passenger views their trip history. This migration
--    broadens the condition to also cover "the requesting passenger has (or
--    has had) an order with this rider" -- still the exact same non-sensitive
--    columns, never Aadhaar/PAN/DL/document columns, and additionally
--    exposes vehicle_image (omitted from the original view by oversight --
--    the storage bucket policy already grants any authenticated user SELECT
--    on every rider's vehicle_image.jpg object, so the DB-row path leaking
--    the same file is not a new exposure).
-- =====================================================================
--
-- RECONCILIATION NOTE (2026-08-04): applied directly to the linked Supabase project but never
-- committed to this repo; reconstructed verbatim from supabase_migrations.schema_migrations.

-- Note: vehicle_image is appended AFTER the original column list (rather than
-- alongside rider_image where it conceptually belongs) because Postgres's
-- CREATE OR REPLACE VIEW only allows adding new columns at the END of the
-- SELECT list -- inserting one in the middle is rejected as an attempted
-- column rename (42P16) of every column after it.
CREATE OR REPLACE VIEW public.rider_kyc_public AS
SELECT
    k.user_id,
    k.full_name,
    k.vehicle_type,
    k.vehicle_number,
    k.rider_image,
    k.kyc_status,
    k.vehicle_image
FROM public.rider_kyc k
JOIN public.riders r ON r.user_id = k.user_id
WHERE r.account_status = 'online'
   OR EXISTS (
       SELECT 1 FROM public.orders o
       WHERE o.rider_id = r.id
         AND o.user_id = auth.uid()
   );

GRANT SELECT ON public.rider_kyc_public TO authenticated;
