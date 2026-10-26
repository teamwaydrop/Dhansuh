-- =============================================================================
-- POLICE DISCLOSURE -- operator-friendly tabular reports for the Supabase SQL Editor
--
-- Thin, specialised RETURNS TABLE reports built on the SAME controlled
-- SECURITY DEFINER data-access path as public.lawful_disclosure_report(...),
-- which is LEFT UNCHANGED for full JSON/export use.
--
-- Adds:
--   public._police_disclosure_gate(...)   -- internal: auth gate + phone
--                                            normalise + find ALL matches +
--                                            record ONE immutable
--                                            lawful_disclosure_requests row
--                                            (+ admin_logs) -- audit-first.
--   public.police_person_details(p_phone, ...)   -- person / KYC / profile only
--   public.police_last_trip(p_phone, ...)        -- exactly the latest trip
--   public.police_all_trips(p_phone, ...)        -- one row per trip (pax + rider)
--   public.police_trip_evidence(p_order_code, ...) -- wide per-order evidence
--
-- SECURITY (identical model to lawful_disclosure_report):
--   * SECURITY DEFINER, SET search_path = public, VOLATILE (records audit).
--   * Gate: public.is_admin() OR auth.role()='service_role' OR the Supabase SQL
--     console / pg_cron (no JWT). anon and ordinary authenticated -> insufficient_privilege.
--   * REVOKE ALL FROM PUBLIC, anon; GRANT EXECUTE TO authenticated, service_role.
--   * NO RLS policy on any table is added or changed. The SECURITY DEFINER
--     functions are the only new read path -- rider_kyc / order_verifications /
--     rider_assignments / rider_locations / parcel_security_logs / retention
--     archives keep their existing RLS; ordinary users still cannot read them.
--   * Aadhaar retains the existing legal-review gate: returned ONLY when the
--     caller passes p_legal_review_confirmed => true.
--
-- Does NOT touch: booking, dispatch, ride tracking, GPS, realtime, payment,
-- completion, tax calculation, lawful_disclosure_report, or any Flutter code.
--
-- IDEMPOTENT: CREATE OR REPLACE + guarded GRANT/REVOKE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Internal: authorize + normalise phone + find matches + record the audit row.
-- Returns one row per matching person; a single sentinel row (NULLs, count 0)
-- when there is no match so callers can still emit a "NO MATCH" row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._police_disclosure_gate(
    p_phone                  text,
    p_report                 text,
    p_requesting_authority   text,
    p_legal_basis            text,
    p_reference_number       text,
    p_legal_review_confirmed boolean
)
RETURNS TABLE (
    match_user_id     uuid,
    match_rider_id    uuid,
    match_created_at  timestamptz,
    total_matches     integer,
    disclosure_id     uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_is_admin boolean := public.is_admin();
    v_uid      uuid    := (SELECT auth.uid());
    v_role     text    := COALESCE((SELECT auth.role()), '');
    v_email    text    := (SELECT auth.email());
    v_admin_id uuid;
    v_context  text;
    v_ten      text;
    v_count    integer;
    v_target   uuid;
    v_phone    text;
    v_disc     uuid;
BEGIN
    IF NOT ( v_is_admin OR v_role = 'service_role' OR (v_uid IS NULL AND v_role <> 'anon') ) THEN
        RAISE EXCEPTION 'police disclosure: authorized admin / service_role / SQL console only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NULLIF(btrim(COALESCE(p_requesting_authority,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_requesting_authority is required' USING ERRCODE = 'check_violation';
    END IF;
    IF NULLIF(btrim(COALESCE(p_legal_basis,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_legal_basis is required' USING ERRCODE = 'check_violation';
    END IF;

    IF v_is_admin THEN
        SELECT a.id INTO v_admin_id FROM public.admins a
        WHERE a.email = v_email AND a.is_active = true LIMIT 1;
    END IF;
    v_context := CASE
        WHEN v_admin_id IS NOT NULL     THEN 'admin_jwt:' || COALESCE(v_email,'?')
        WHEN v_role = 'service_role'     THEN 'service_role'
        ELSE 'supabase_sql_console_or_backend' END;

    v_ten := public._normalize_in_phone_10(p_phone);
    IF v_ten IS NULL THEN
        RAISE EXCEPTION 'p_phone must contain at least 10 digits' USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.users u
    WHERE right(regexp_replace(u.phone,'\D','','g'),10) = v_ten;

    SELECT u.id, u.phone INTO v_target, v_phone
    FROM public.users u
    WHERE right(regexp_replace(u.phone,'\D','','g'),10) = v_ten
    ORDER BY u.created_at DESC LIMIT 1;

    INSERT INTO public.lawful_disclosure_requests (
        handled_by_admin_id, requesting_authority, reference_number, legal_basis,
        legal_review_confirmed, target_user_id, target_phone_last4,
        disclosed_scope, result_summary, notes
    ) VALUES (
        v_admin_id, p_requesting_authority,
        NULLIF(btrim(COALESCE(p_reference_number,'')), ''), p_legal_basis,
        COALESCE(p_legal_review_confirmed, false), v_target, right(v_ten, 4),
        ARRAY['police_' || p_report],
        v_count || ' phone match(es)',
        'operator_context=' || v_context || ' | report=police_' || p_report
    )
    RETURNING id INTO v_disc;

    IF v_admin_id IS NOT NULL AND v_target IS NOT NULL THEN
        INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
        VALUES (v_admin_id, 'police_' || p_report, 'users', v_target,
                'Police disclosure report: ' || p_report,
                jsonb_build_object('disclosure_id', v_disc, 'phone_last4', right(v_ten,4),
                                   'requesting_authority', p_requesting_authority, 'matches', v_count));
    END IF;

    IF v_count = 0 THEN
        RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::timestamptz, 0, v_disc;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT u.id, r.id, u.created_at, v_count, v_disc
    FROM public.users u
    LEFT JOIN public.riders r ON r.user_id = u.id
    WHERE right(regexp_replace(u.phone,'\D','','g'),10) = v_ten
    ORDER BY u.created_at DESC;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 1. PERSON DETAILS -- phone only. No rides / trips / GPS / security logs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.police_person_details(
    p_phone                  text,
    p_requesting_authority   text    DEFAULT 'lawful police disclosure (Supabase SQL editor)',
    p_legal_basis            text    DEFAULT 'lawful request - written reference to follow',
    p_reference_number       text    DEFAULT NULL,
    p_legal_review_confirmed boolean DEFAULT false
)
RETURNS TABLE (
    total_matches           integer,
    resolution_hint         text,
    user_id                 uuid,
    rider_id                uuid,
    user_code               text,
    full_name               text,
    phone                   text,
    email                   text,
    gender                  text,
    date_of_birth           date,
    father_name             text,
    kyc_status              text,
    activation_status       text,
    driving_license_number  text,
    pan_number              text,
    aadhaar_number          text,
    aadhaar_note            text,
    vehicle_type            text,
    vehicle_number          text,
    additional_vehicles     jsonb,
    rider_account_status    text,
    rider_verified          boolean,
    rider_service_mode      text,
    rider_rating            numeric,
    kyc_source              text,
    account_deleted_at      timestamptz,
    profile_photo_path      text,
    kyc_document_paths      jsonb,
    disclosure_id           uuid
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
            p_phone, 'person_details', p_requesting_authority, p_legal_basis,
            p_reference_number, p_legal_review_confirmed)
    )
    SELECT
        g.total_matches,
        CASE WHEN g.total_matches = 0 THEN 'NO MATCH for this phone'
             WHEN g.total_matches > 1 THEN 'MULTIPLE MATCHES -- one row per matching person; disambiguate by user_id'
             ELSE 'single match' END,
        u.id,
        r.id,
        u.user_code,
        u.full_name,
        u.phone,
        u.email,
        u.gender,
        COALESCE(k.date_of_birth, ar.date_of_birth),
        COALESCE(k.father_name, ar.father_name),
        COALESCE(k.kyc_status::text, CASE WHEN ar.id IS NOT NULL THEN 'archived' END),
        k.activation_status::text,
        COALESCE(k.driving_license_number, ar.driving_license_number),
        COALESCE(k.pan_number, ar.pan_number),
        CASE WHEN COALESCE(p_legal_review_confirmed, false)
             THEN COALESCE(k.aadhaar_number, ar.aadhaar_number) ELSE NULL END,
        CASE WHEN COALESCE(p_legal_review_confirmed, false) THEN NULL
             ELSE 'Aadhaar withheld -- re-run with p_legal_review_confirmed => true (and a written legal basis) to include it' END,
        COALESCE(k.vehicle_type::text, ar.vehicle_type),
        COALESCE(k.vehicle_number, ar.vehicle_number),
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', rv.id, 'vehicle_type', rv.vehicle_type::text, 'vehicle_number', rv.vehicle_number,
                'status', rv.status, 'reviewed_at', rv.reviewed_at))
            FROM public.rider_vehicles rv WHERE rv.rider_id = r.id), '[]'::jsonb),
        r.account_status::text,
        r.is_verified,
        r.service_mode::text,
        r.rating,
        CASE WHEN k.id IS NOT NULL THEN 'rider_kyc'
             WHEN ar.id IS NOT NULL THEN 'rider_kyc_retention_archive'
             WHEN g.match_user_id IS NULL THEN NULL
             ELSE 'none' END,
        u.deleted_at,
        u.profile_photo_url,
        jsonb_strip_nulls(jsonb_build_object(
            'bucket', 'rider_kyc (private -- generate short-lived signed URLs via Storage dashboard / REST /storage/v1/object/sign)',
            'rider_image', k.rider_image,
            'aadhaar_front_image', k.aadhaar_front_image,
            'aadhaar_back_image', k.aadhaar_back_image,
            'pan_front_image', k.pan_front_image,
            'pan_back_image', k.pan_back_image,
            'license_front_image', k.license_front_image,
            'license_back_image', k.license_back_image,
            'vehicle_image', k.vehicle_image,
            'vehicle_rc_front_image', k."VECHILE_RC_front_image",
            'vehicle_rc_back_image', k."VECHILE_RC_back_image",
            'archive_paths', CASE WHEN ar.id IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
                'rider_image_path', ar.rider_image_path,
                'aadhaar_front_image_path', ar.aadhaar_front_image_path,
                'aadhaar_back_image_path', ar.aadhaar_back_image_path,
                'pan_front_image_path', ar.pan_front_image_path,
                'pan_back_image_path', ar.pan_back_image_path,
                'license_front_image_path', ar.license_front_image_path,
                'license_back_image_path', ar.license_back_image_path,
                'vehicle_image_path', ar.vehicle_image_path,
                'vehicle_rc_front_image_path', ar.vehicle_rc_front_image_path,
                'vehicle_rc_back_image_path', ar.vehicle_rc_back_image_path)) END
        )),
        g.disclosure_id
    FROM g
    LEFT JOIN public.users  u ON u.id = g.match_user_id
    LEFT JOIN public.riders r ON r.id = g.match_rider_id
    LEFT JOIN public.rider_kyc k ON k.user_id = g.match_user_id
    LEFT JOIN LATERAL (
        SELECT * FROM public.rider_kyc_retention_archive a
        WHERE a.user_id = g.match_user_id ORDER BY a.created_at DESC LIMIT 1
    ) ar ON true
    ORDER BY u.created_at DESC NULLS LAST;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 2. LAST TRIP -- phone only. Exactly the person's most-recent order
--    (across passenger + rider roles). One row per matching person.
-- -----------------------------------------------------------------------------
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
         FROM public.police_sos_logs s WHERE s.order_id = latest.id OR (latest.prid IS NOT NULL AND s.rider_id = latest.prid)),
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


-- -----------------------------------------------------------------------------
-- 3. ALL TRIPS -- phone only. One row per order (passenger + rider), newest first.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.police_all_trips(
    p_phone                text,
    p_requesting_authority text DEFAULT 'lawful police disclosure (Supabase SQL editor)',
    p_legal_basis          text DEFAULT 'lawful request - written reference to follow',
    p_reference_number     text DEFAULT NULL
)
RETURNS TABLE (
    total_person_matches integer,
    user_id              uuid,
    rider_id             uuid,
    order_id             uuid,
    order_code           text,
    role                 text,
    order_type           text,
    status               text,
    created_at           timestamptz,
    accepted_at          timestamptz,
    rider_arrived_at     timestamptz,
    picked_up_at         timestamptz,
    trip_started_at      timestamptz,
    rider_at_drop_at     timestamptz,
    completed_at         timestamptz,
    cancelled_at         timestamptz,
    pickup_address       text,
    pickup_lat           double precision,
    pickup_lng           double precision,
    destination_address  text,
    destination_lat      double precision,
    destination_lng      double precision,
    final_fare           numeric,
    payment_method       text,
    payment_status       text,
    gst_amount           numeric,
    rider_earning        numeric,
    receiver_name        text,
    receiver_phone       text,
    is_parcel            boolean,
    parcel               jsonb,
    disclosure_id        uuid
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
            p_phone, 'all_trips', p_requesting_authority, p_legal_basis, p_reference_number, false)
    ),
    persons AS (
        SELECT g.match_user_id AS puid, g.match_rider_id AS prid,
               g.total_matches AS tm, g.disclosure_id AS did FROM g
    )
    SELECT
        p.tm,
        p.puid,
        p.prid,
        o.id, o.order_code,
        CASE WHEN o.user_id = p.puid AND o.rider_id = p.prid THEN 'both'
             WHEN o.user_id = p.puid THEN 'passenger'
             ELSE 'rider' END,
        o.order_type::text, o.order_status::text,
        o.created_at, o.accepted_at, o.rider_arrived_at, o.picked_up_at,
        o.trip_started_at, o.rider_at_drop_at, o.completed_at, o.cancelled_at,
        o.pickup_address, o.pickup_lat, o.pickup_lng,
        o.destination_address, o.destination_lat, o.destination_lng,
        o.final_fare, o.fare_payment_method::text, o.payment_status::text,
        o.gst_amount, o.rider_earning, o.receiver_name, o.receiver_phone,
        (o.order_type::text LIKE '%parcel%'),
        CASE WHEN o.order_type::text LIKE '%parcel%' THEN jsonb_build_object(
            'parcel_type', o.parcel_type::text, 'weight_category', o.weight_category,
            'actual_weight_kg', o.actual_weight_kg, 'declared_value', o.parcel_declared_value,
            'special_instructions', o.special_instructions, 'high_risk_parcel', o.high_risk_parcel,
            'parcel_image_paths', to_jsonb(o.parcel_images),
            'run_police_trip_evidence_with', o.order_code) END,
        p.did
    FROM persons p
    JOIN public.orders o ON (
        (p.puid IS NOT NULL AND o.user_id = p.puid)
        OR (p.prid IS NOT NULL AND o.rider_id = p.prid)
    )
    WHERE p.puid IS NOT NULL
    ORDER BY o.created_at DESC;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 4. TRIP EVIDENCE -- one order (by order_code). The wide per-order evidence
--    (verifications, security logs, SOS, status + assignment history).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.police_trip_evidence(
    p_order_code           text,
    p_requesting_authority text DEFAULT 'lawful police disclosure (Supabase SQL editor)',
    p_legal_basis          text DEFAULT 'lawful request - written reference to follow',
    p_reference_number     text DEFAULT NULL
)
RETURNS TABLE (
    order_id            uuid,
    order_code          text,
    order_type          text,
    status              text,
    created_at          timestamptz,
    passenger           jsonb,
    assigned_rider      jsonb,
    addresses           jsonb,
    parcel_details      jsonb,
    parcel_image_paths  jsonb,
    verifications       jsonb,
    security_logs       jsonb,
    police_sos          jsonb,
    status_history      jsonb,
    assignment_history  jsonb,
    disclosure_id       uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
    v_is_admin boolean := public.is_admin();
    v_uid      uuid    := (SELECT auth.uid());
    v_role     text    := COALESCE((SELECT auth.role()), '');
    v_email    text    := (SELECT auth.email());
    v_admin_id uuid;
    v_context  text;
    v_order    record;
    v_disc     uuid;
BEGIN
    IF NOT ( v_is_admin OR v_role = 'service_role' OR (v_uid IS NULL AND v_role <> 'anon') ) THEN
        RAISE EXCEPTION 'police disclosure: authorized admin / service_role / SQL console only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NULLIF(btrim(COALESCE(p_requesting_authority,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_requesting_authority is required' USING ERRCODE = 'check_violation';
    END IF;
    IF NULLIF(btrim(COALESCE(p_legal_basis,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_legal_basis is required' USING ERRCODE = 'check_violation';
    END IF;

    IF v_is_admin THEN
        SELECT a.id INTO v_admin_id FROM public.admins a WHERE a.email = v_email AND a.is_active = true LIMIT 1;
    END IF;
    v_context := CASE WHEN v_admin_id IS NOT NULL THEN 'admin_jwt:'||COALESCE(v_email,'?')
                      WHEN v_role='service_role' THEN 'service_role'
                      ELSE 'supabase_sql_console_or_backend' END;

    SELECT o.id, o.user_id, o.rider_id INTO v_order
    FROM public.orders o WHERE o.order_code = btrim(p_order_code) LIMIT 1;

    INSERT INTO public.lawful_disclosure_requests (
        handled_by_admin_id, requesting_authority, reference_number, legal_basis,
        legal_review_confirmed, target_user_id, target_phone_last4,
        disclosed_scope, result_summary, notes
    ) VALUES (
        v_admin_id, p_requesting_authority,
        NULLIF(btrim(COALESCE(p_reference_number,'')), ''), p_legal_basis,
        false, v_order.user_id,
        (SELECT right(regexp_replace(COALESCE(u.phone,''),'\D','','g'),4) FROM public.users u WHERE u.id = v_order.user_id),
        ARRAY['police_trip_evidence'],
        CASE WHEN v_order.id IS NULL THEN 'order_code not found' ELSE 'order ' || btrim(p_order_code) END,
        'operator_context=' || v_context || ' | report=police_trip_evidence | order_code=' || btrim(p_order_code)
    )
    RETURNING id INTO v_disc;

    IF v_admin_id IS NOT NULL AND v_order.user_id IS NOT NULL THEN
        INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
        VALUES (v_admin_id, 'police_trip_evidence', 'orders', v_order.id,
                'Police disclosure: trip evidence for ' || btrim(p_order_code),
                jsonb_build_object('disclosure_id', v_disc, 'order_code', btrim(p_order_code)));
    END IF;

    IF v_order.id IS NULL THEN
        RETURN QUERY SELECT NULL::uuid, btrim(p_order_code), NULL::text, NULL::text, NULL::timestamptz,
            'null'::jsonb, 'null'::jsonb, 'null'::jsonb, 'null'::jsonb, '[]'::jsonb, '[]'::jsonb,
            '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, v_disc;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        o.id, o.order_code, o.order_type::text, o.order_status::text, o.created_at,
        (SELECT jsonb_build_object('user_id', u.id, 'full_name', u.full_name, 'phone', u.phone, 'email', u.email)
         FROM public.users u WHERE u.id = o.user_id),
        (SELECT jsonb_build_object('rider_id', r.id, 'user_id', ru.id, 'full_name', ru.full_name,
                                   'phone', ru.phone, 'account_status', r.account_status::text)
         FROM public.riders r JOIN public.users ru ON ru.id = r.user_id WHERE r.id = o.rider_id),
        jsonb_build_object(
            'pickup_address', o.pickup_address, 'pickup_lat', o.pickup_lat, 'pickup_lng', o.pickup_lng,
            'destination_address', o.destination_address, 'destination_lat', o.destination_lat,
            'destination_lng', o.destination_lng, 'created_lat', o.created_lat, 'created_lng', o.created_lng,
            'created_ip_address', o.created_ip_address::text),
        CASE WHEN o.order_type::text LIKE '%parcel%' THEN jsonb_build_object(
            'parcel_type', o.parcel_type::text, 'weight_category', o.weight_category,
            'actual_weight_kg', o.actual_weight_kg, 'declared_value', o.parcel_declared_value,
            'special_instructions', o.special_instructions, 'high_risk_parcel', o.high_risk_parcel,
            'receiver_name', o.receiver_name, 'receiver_phone', o.receiver_phone,
            'sender_declaration_accepted', o.sender_declaration_accepted,
            'sender_declaration_accepted_at', o.sender_declaration_accepted_at) END,
        to_jsonb(o.parcel_images),
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'verification_type', ov.verification_type, 'verification_status', ov.verification_status,
            'photo_url', ov.photo_url, 'latitude', ov.latitude, 'longitude', ov.longitude,
            'created_by', ov.created_by, 'created_at', ov.created_at, 'metadata', ov.metadata) ORDER BY ov.created_at)
         FROM public.order_verifications ov WHERE ov.order_id = o.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'event_type', pl.event_type, 'latitude', pl.latitude, 'longitude', pl.longitude,
            'event_latitude', pl.event_latitude, 'event_longitude', pl.event_longitude,
            'ip_address', pl.ip_address::text, 'device_id', pl.device_id, 'photo_url', pl.photo_url,
            'metadata', pl.metadata, 'created_at', pl.created_at) ORDER BY pl.created_at)
         FROM public.parcel_security_logs pl WHERE pl.order_id = o.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'opened_at', s.opened_at, 'latitude', s.latitude, 'longitude', s.longitude,
            'rider_lat', s.rider_lat, 'rider_lng', s.rider_lng,
            'police_reference_code', s.police_reference_code, 'support_ticket_code', s.support_ticket_code,
            'notes', s.notes) ORDER BY s.opened_at DESC)
         FROM public.police_sos_logs s WHERE s.order_id = o.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'previous_status', h.previous_status, 'new_status', h.new_status, 'changed_by', h.changed_by,
            'changed_by_rider_id', h.changed_by_rider_id, 'changed_by_user_id', h.changed_by_user_id,
            'changed_by_admin_id', h.changed_by_admin_id, 'notes', h.notes, 'metadata', h.metadata,
            'created_at', h.created_at) ORDER BY h.created_at)
         FROM public.order_status_history h WHERE h.order_id = o.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rider_id', ra.rider_id, 'assignment_round', ra.assignment_round,
            'assignment_status', ra.assignment_status::text, 'response_type', ra.response_type,
            'sent_at', ra.sent_at, 'viewed_at', ra.viewed_at, 'responded_at', ra.responded_at,
            'accepted_at', ra.accepted_at, 'rejected_at', ra.rejected_at, 'expires_at', ra.expires_at)
            ORDER BY ra.sent_at)
         FROM public.rider_assignments ra WHERE ra.order_id = o.id), '[]'::jsonb),
        v_disc
    FROM public.orders o WHERE o.id = v_order.id;
END;
$function$;


-- -----------------------------------------------------------------------------
-- Grants: authenticated (self-gated) + service_role. Never anon / PUBLIC.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._police_disclosure_gate(text, text, text, text, text, boolean)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.police_person_details(text, text, text, text, boolean)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.police_last_trip(text, text, text, text)                            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.police_all_trips(text, text, text, text)                            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.police_trip_evidence(text, text, text, text)                        FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._police_disclosure_gate(text, text, text, text, text, boolean)   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.police_person_details(text, text, text, text, boolean)           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.police_last_trip(text, text, text, text)                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.police_all_trips(text, text, text, text)                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.police_trip_evidence(text, text, text, text)                     TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.police_trip_evidence(text, text, text, text);
--   DROP FUNCTION IF EXISTS public.police_all_trips(text, text, text, text);
--   DROP FUNCTION IF EXISTS public.police_last_trip(text, text, text, text);
--   DROP FUNCTION IF EXISTS public.police_person_details(text, text, text, text, boolean);
--   DROP FUNCTION IF EXISTS public._police_disclosure_gate(text, text, text, text, text, boolean);
-- (No schema, RLS, trigger, or other object changed. lawful_disclosure_report untouched.)
-- =============================================================================
