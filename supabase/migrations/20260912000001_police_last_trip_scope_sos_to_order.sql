-- =============================================================================
-- FOLLOW-UP to 20260912000000_police_disclosure_tabular_reports.sql
--
-- Bug found in selftest: public.police_last_trip(...).police_sos was scoped as
--   WHERE s.order_id = latest.id OR (latest.prid IS NOT NULL AND s.rider_id = latest.prid)
-- The second branch pulled EVERY police-SOS event from the person's entire rider
-- career into a report about ONE specific (often passenger-side) trip. A report
-- titled "last trip" must only carry evidence for that trip.
--
-- Fix: police_sos is now scoped strictly to the shown order:
--   WHERE s.order_id = latest.id
--
-- Nothing else changes. CREATE OR REPLACE, idempotent, same signature / grants.
-- (police_trip_evidence(order_code) remains the tool for a full per-order dump,
--  and police_last_trip still surfaces rider snapshot GPS + the phone-off note.)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.police_last_trip(
    p_phone                text,
    p_requesting_authority text DEFAULT 'lawful police disclosure (Supabase SQL editor)',
    p_legal_basis          text DEFAULT 'lawful request - written reference to follow',
    p_reference_number     text DEFAULT NULL
)
RETURNS TABLE (
    total_person_matches               integer,
    resolution_hint                    text,
    user_id                            uuid,
    rider_id                           uuid,
    order_id                           uuid,
    order_code                         text,
    role                               text,
    order_type                         text,
    status                             text,
    created_at                         timestamptz,
    accepted_at                        timestamptz,
    rider_arrived_at                   timestamptz,
    picked_up_at                       timestamptz,
    trip_started_at                    timestamptz,
    rider_at_drop_at                   timestamptz,
    completed_at                       timestamptz,
    cancelled_at                       timestamptz,
    cancelled_by                       text,
    cancel_reason                      text,
    pickup_address                     text,
    pickup_lat                         double precision,
    pickup_lng                         double precision,
    destination_address                text,
    destination_lat                    double precision,
    destination_lng                    double precision,
    final_fare                         numeric,
    current_fare                       numeric,
    payment_method                     text,
    payment_status                     text,
    gst_amount                         numeric,
    rider_earning                      numeric,
    receiver_name                      text,
    receiver_phone                     text,
    is_parcel                          boolean,
    parcel_details                     jsonb,
    pickup_verification                jsonb,
    drop_verification                  jsonb,
    parcel_security_events             jsonb,
    police_sos                         jsonb,
    last_known_lat                     double precision,
    last_known_lng                     double precision,
    last_location_updated_at           timestamptz,
    last_active_at                     timestamptz,
    continuous_route_history_available boolean,
    location_note                      text,
    phone_off_note                     text,
    disclosure_id                      uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH g AS (
        SELECT * FROM public._police_disclosure_gate(
            p_phone, 'last_trip', p_requesting_authority, p_legal_basis, p_reference_number, false)
    ),
    persons AS (
        SELECT g.match_user_id AS puid, g.match_rider_id AS prid,
               g.total_matches AS tm, g.disclosure_id AS did
        FROM g
    ),
    latest AS (
        SELECT p.puid, p.prid, p.tm, p.did, o.*,
               CASE WHEN o.id IS NULL THEN NULL
                    WHEN o.user_id = p.puid AND o.rider_id = p.prid THEN 'both'
                    WHEN o.user_id = p.puid THEN 'passenger'
                    ELSE 'rider' END AS trip_role
        FROM persons p
        LEFT JOIN LATERAL (
            SELECT o2.* FROM public.orders o2
            WHERE (p.puid IS NOT NULL AND o2.user_id = p.puid)
               OR (p.prid IS NOT NULL AND o2.rider_id = p.prid)
            ORDER BY o2.created_at DESC LIMIT 1
        ) o ON true
    )
    SELECT
        latest.tm,
        CASE WHEN latest.tm = 0 THEN 'NO MATCH for this phone'
             WHEN latest.tm > 1 THEN 'MULTIPLE MATCHES -- latest trip shown per matching person; disambiguate by user_id'
             WHEN latest.id IS NULL THEN 'person found but has no orders'
             ELSE 'single match' END,
        latest.puid, latest.prid, latest.id, latest.order_code, latest.trip_role,
        latest.order_type::text, latest.order_status::text,
        latest.created_at, latest.accepted_at, latest.rider_arrived_at, latest.picked_up_at,
        latest.trip_started_at, latest.rider_at_drop_at, latest.completed_at, latest.cancelled_at,
        latest.cancelled_by::text, latest.cancel_reason,
        latest.pickup_address, latest.pickup_lat, latest.pickup_lng,
        latest.destination_address, latest.destination_lat, latest.destination_lng,
        latest.final_fare, latest.current_fare, latest.fare_payment_method::text,
        latest.payment_status::text, latest.gst_amount, latest.rider_earning,
        latest.receiver_name, latest.receiver_phone,
        (latest.order_type::text LIKE '%parcel%'),
        CASE WHEN latest.order_type::text LIKE '%parcel%' THEN jsonb_build_object(
            'parcel_type', latest.parcel_type::text, 'weight_category', latest.weight_category,
            'actual_weight_kg', latest.actual_weight_kg, 'declared_value', latest.parcel_declared_value,
            'special_instructions', latest.special_instructions, 'high_risk_parcel', latest.high_risk_parcel,
            'parcel_image_paths', to_jsonb(latest.parcel_images),
            'parcel_image_bucket', 'parcel_images (public)',
            'sender_declaration_accepted', latest.sender_declaration_accepted,
            'sender_declaration_accepted_at', latest.sender_declaration_accepted_at,
            'pickup_verification_completed', latest.pickup_verification_completed,
            'pickup_verification_completed_at', latest.pickup_verification_completed_at) END,
        (SELECT jsonb_agg(jsonb_build_object(
            'verification_status', ov.verification_status, 'photo_url', ov.photo_url,
            'latitude', ov.latitude, 'longitude', ov.longitude,
            'created_by', ov.created_by, 'created_at', ov.created_at, 'metadata', ov.metadata))
         FROM public.order_verifications ov WHERE ov.order_id = latest.id AND ov.verification_type = 'pickup'),
        (SELECT jsonb_agg(jsonb_build_object(
            'verification_status', ov.verification_status, 'photo_url', ov.photo_url,
            'latitude', ov.latitude, 'longitude', ov.longitude,
            'created_by', ov.created_by, 'created_at', ov.created_at, 'metadata', ov.metadata))
         FROM public.order_verifications ov WHERE ov.order_id = latest.id AND ov.verification_type = 'dropoff'),
        (SELECT jsonb_agg(jsonb_build_object(
            'event_type', pl.event_type, 'latitude', pl.latitude, 'longitude', pl.longitude,
            'event_latitude', pl.event_latitude, 'event_longitude', pl.event_longitude,
            'ip_address', pl.ip_address::text, 'device_id', pl.device_id,
            'photo_url', pl.photo_url, 'metadata', pl.metadata, 'created_at', pl.created_at)
            ORDER BY pl.created_at)
         FROM public.parcel_security_logs pl WHERE pl.order_id = latest.id),
        (SELECT jsonb_agg(jsonb_build_object(
            'opened_at', s.opened_at, 'latitude', s.latitude, 'longitude', s.longitude,
            'rider_lat', s.rider_lat, 'rider_lng', s.rider_lng,
            'police_reference_code', s.police_reference_code,
            'support_ticket_code', s.support_ticket_code, 'notes', s.notes) ORDER BY s.opened_at DESC)
         FROM public.police_sos_logs s WHERE s.order_id = latest.id),
        (SELECT rr.current_lat            FROM public.riders rr WHERE rr.id = latest.prid),
        (SELECT rr.current_lng            FROM public.riders rr WHERE rr.id = latest.prid),
        (SELECT rr.last_location_updated_at FROM public.riders rr WHERE rr.id = latest.prid),
        (SELECT rr.last_active_at         FROM public.riders rr WHERE rr.id = latest.prid),
        false,
        'last_known_lat/lng is the single most-recent GPS snapshot (riders table), overwritten on the next ping. There is NO continuous route / breadcrumb history stored anywhere.',
        'All persisted trip/evidence data above remains retrievable regardless of the device being switched off afterwards. Live / current location CANNOT be obtained while the device is offline -- only the last snapshot above.',
        latest.did
    FROM latest
    ORDER BY latest.created_at DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.police_last_trip(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.police_last_trip(text, text, text, text) TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual): re-apply the police_last_trip body from
--   20260912000000_police_disclosure_tabular_reports.sql
-- =============================================================================
