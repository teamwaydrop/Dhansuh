-- =============================================================================
-- LAWFUL DISCLOSURE -- single Supabase-SQL-Editor function
--
-- public.lawful_disclosure_report(phone, authority, legal_basis, scope[], ...)
--
-- One call from the Supabase Dashboard -> SQL Editor:
--   * verifies caller is an admin / service_role / the SQL console (no JWT),
--   * normalises the phone with the EXISTING _normalize_in_phone_10(),
--   * returns ALL matching users (never silently picks one),
--   * records an immutable lawful_disclosure_requests audit row (same table &
--     immutability guarantees as admin_record_lawful_disclosure -- the INSERT is
--     inlined here because admin_record_lawful_disclosure's internal is_admin()
--     gate cannot be satisfied from the SQL console, which carries no JWT),
--   * records an admin_logs retrieval row when a real admin identity exists,
--   * returns one scoped JSON report drawn from data that ALREADY exists in the
--     database (identity, KYC, KYC document paths, vehicle, trips w/ all
--     timestamps + coordinates, order_status_history, rider_assignments,
--     parcel evidence incl. order_verifications + parcel_security_logs, SOS,
--     last-known-location snapshot).
--
-- LEAST PRIVILEGE:
--   SECURITY DEFINER (owner = postgres) is the ONLY new read path. It reads the
--   evidence tables (order_verifications, rider_assignments, rider_locations/
--   riders, rider_kyc, rider_kyc_retention_archive, parcel_security_logs) as the
--   definer. NO RLS policy on any of those tables is added or changed. Ordinary
--   authenticated mobile users still cannot read them and cannot call this
--   function (REVOKEd from PUBLIC/anon; is_admin()/service-role/console gate).
--
-- NOT A LEGAL DETERMINATION: `p_legal_review_confirmed` is an explicit operator
-- attestation. Aadhaar is returned ONLY when scope contains 'aadhaar' AND
-- p_legal_review_confirmed = true.
--
-- The mobile app has NO code path that calls this function and no admin UI.
-- IDEMPOTENT: CREATE OR REPLACE + guarded ALTER + guarded GRANT/REVOKE.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Minimal, required schema touch: lawful_disclosure_requests.handled_by_admin_id
-- was created NOT NULL (migration 20260910000003). A disclosure recorded from the
-- Supabase SQL console has no admin identity, so this one column is made nullable
-- (table has 0 rows; fully reversible). The operator execution context is
-- recorded in `notes`. No other column / constraint / policy is changed.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='lawful_disclosure_requests'
          AND column_name='handled_by_admin_id' AND is_nullable='NO'
    ) THEN
        ALTER TABLE public.lawful_disclosure_requests
            ALTER COLUMN handled_by_admin_id DROP NOT NULL;
        RAISE NOTICE 'lawful_disclosure_requests.handled_by_admin_id -> NULLABLE';
    END IF;
END $$;


CREATE OR REPLACE FUNCTION public.lawful_disclosure_report(
    p_phone                  text,
    p_requesting_authority   text,
    p_legal_basis            text,
    p_disclosed_scope        text[],
    p_reference_number       text    DEFAULT NULL,
    p_legal_review_confirmed boolean DEFAULT false,
    p_notes                  text    DEFAULT NULL,
    p_generate_signed_urls   boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE                      -- records audit rows
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_is_admin      boolean := public.is_admin();
    v_jwt_uid       uuid    := (SELECT auth.uid());
    v_jwt_role      text    := COALESCE((SELECT auth.role()), '');
    v_jwt_email     text    := (SELECT auth.email());
    v_admin_id      uuid;
    v_context       text;

    v_scope         text[]  := COALESCE(p_disclosed_scope, '{}'::text[]);
    v_ten           text;
    v_matches       jsonb;
    v_match_count   int;
    v_multi         boolean := false;
    v_target        uuid;           -- user_id used for the detail sections
    v_rider_id      uuid;
    v_user          record;
    v_deleted       boolean := false;

    v_disclosure_id uuid;
    v_admin_logged  boolean := false;

    v_identity      jsonb := 'null'::jsonb;
    v_kyc           jsonb := 'null'::jsonb;
    v_kyc_docs      jsonb := 'null'::jsonb;
    v_vehicle       jsonb := 'null'::jsonb;
    v_pax_trips     jsonb := '[]'::jsonb;
    v_rider_trips   jsonb := '[]'::jsonb;
    v_status_hist   jsonb := '[]'::jsonb;
    v_assign_hist   jsonb := '[]'::jsonb;
    v_parcel_ev     jsonb := '[]'::jsonb;
    v_sos           jsonb := '[]'::jsonb;
    v_last_loc      jsonb := 'null'::jsonb;
    v_storage_objs  jsonb := 'null'::jsonb;
BEGIN
    -- ---- 1. AUTHORIZATION ------------------------------------------------------
    -- Allowed: a real admin JWT (is_admin()), a service_role JWT, OR the Supabase
    -- SQL console / pg_cron / trusted backend (no JWT at all). Ordinary
    -- authenticated users and anon are rejected. (Same reasoning as
    -- prevent_role_self_escalation: no JWT => trusted out-of-band context.)
    IF NOT (
        v_is_admin
        OR v_jwt_role = 'service_role'
        OR (v_jwt_uid IS NULL AND v_jwt_role <> 'anon')
    ) THEN
        RAISE EXCEPTION 'lawful_disclosure_report: authorized admin / service_role / SQL console only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NULLIF(btrim(COALESCE(p_requesting_authority,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_requesting_authority is required' USING ERRCODE = 'check_violation';
    END IF;
    IF NULLIF(btrim(COALESCE(p_legal_basis,'')), '') IS NULL THEN
        RAISE EXCEPTION 'p_legal_basis is required' USING ERRCODE = 'check_violation';
    END IF;

    IF v_is_admin THEN
        SELECT id INTO v_admin_id FROM public.admins
        WHERE email = v_jwt_email AND is_active = true LIMIT 1;
    END IF;

    v_context := CASE
        WHEN v_admin_id IS NOT NULL      THEN 'admin_jwt:' || COALESCE(v_jwt_email,'?')
        WHEN v_jwt_role = 'service_role'  THEN 'service_role'
        ELSE 'supabase_sql_console_or_backend'
    END;

    -- ---- 2. PHONE NORMALISE + FIND ALL MATCHES ------------------------------
    v_ten := public._normalize_in_phone_10(p_phone);
    IF v_ten IS NULL THEN
        RAISE EXCEPTION 'p_phone must contain at least 10 digits' USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(jsonb_agg(m ORDER BY m->>'created_at' DESC), '[]'::jsonb), count(*)
    INTO v_matches, v_match_count
    FROM (
        SELECT jsonb_build_object(
            'user_id',     u.id,
            'full_name',   u.full_name,
            'user_code',   u.user_code,
            'email',       u.email,
            'phone_last4', right(regexp_replace(u.phone,'\D','','g'), 4),
            'created_at',  u.created_at,
            'deleted_at',  u.deleted_at,
            'is_rider',    (r.id IS NOT NULL),
            'rider_id',    r.id,
            'account_status', r.account_status::text
        ) AS m
        FROM public.users u
        LEFT JOIN public.riders r ON r.user_id = u.id
        WHERE right(regexp_replace(u.phone,'\D','','g'), 10) = v_ten
    ) s;

    v_multi := (v_match_count > 1);

    -- ---- 3. RECORD THE LAWFUL-DISCLOSURE AUDIT ROW (always, even on no match) --
    -- pick the detail target = most recently created match (documented; all
    -- matches are returned in `matched_users`).
    IF v_match_count >= 1 THEN
        SELECT u.id, r.id
        INTO v_target, v_rider_id
        FROM public.users u
        LEFT JOIN public.riders r ON r.user_id = u.id
        WHERE right(regexp_replace(u.phone,'\D','','g'), 10) = v_ten
        ORDER BY u.created_at DESC
        LIMIT 1;

        SELECT (deleted_at IS NOT NULL) INTO v_deleted FROM public.users WHERE id = v_target;
    END IF;

    INSERT INTO public.lawful_disclosure_requests (
        handled_by_admin_id, requesting_authority, reference_number, legal_basis,
        legal_review_confirmed, target_user_id, target_phone_last4,
        disclosed_scope, result_summary, notes
    ) VALUES (
        v_admin_id,
        p_requesting_authority,
        NULLIF(btrim(COALESCE(p_reference_number,'')), ''),
        p_legal_basis,
        COALESCE(p_legal_review_confirmed, false),
        v_target,
        right(v_ten, 4),
        v_scope,
        CASE WHEN v_match_count = 0 THEN 'no matching user'
             WHEN v_multi           THEN v_match_count || ' users matched; detail = most recent'
             ELSE '1 user matched' END,
        'operator_context=' || v_context
        || CASE WHEN NULLIF(btrim(COALESCE(p_notes,'')),'') IS NOT NULL
                THEN ' | ' || btrim(p_notes) ELSE '' END
    )
    RETURNING id INTO v_disclosure_id;

    IF v_admin_id IS NOT NULL AND v_target IS NOT NULL THEN
        INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
        VALUES (v_admin_id, 'lawful_disclosure_report', 'users', v_target,
                'Lawful disclosure report generated',
                jsonb_build_object('disclosure_id', v_disclosure_id,
                                   'requesting_authority', p_requesting_authority,
                                   'disclosed_scope', to_jsonb(v_scope),
                                   'phone_last4', right(v_ten,4),
                                   'multiple_phone_matches', v_multi));
        v_admin_logged := true;
    END IF;

    -- ---- 4. NO MATCH -> return early (disclosure attempt still recorded) ----
    IF v_match_count = 0 THEN
        RETURN jsonb_build_object(
            'request', jsonb_build_object(
                'generated_at', now(), 'requesting_authority', p_requesting_authority,
                'legal_basis', p_legal_basis, 'reference_number', p_reference_number,
                'legal_review_confirmed', COALESCE(p_legal_review_confirmed,false),
                'disclosed_scope', to_jsonb(v_scope), 'phone_input_last4', right(v_ten,4)),
            'matched_users', '[]'::jsonb,
            'multiple_phone_matches', false,
            'user_not_found', true,
            'identity', 'null'::jsonb, 'kyc', 'null'::jsonb, 'kyc_documents', 'null'::jsonb,
            'vehicle', 'null'::jsonb, 'rides_as_passenger', '[]'::jsonb, 'rides_as_rider', '[]'::jsonb,
            'status_history', '[]'::jsonb, 'assignment_history', '[]'::jsonb,
            'parcel_evidence', '[]'::jsonb, 'police_sos', '[]'::jsonb,
            'last_known_location', 'null'::jsonb,
            'location_limitations', jsonb_build_object(
                'snapshot_not_route', true, 'continuous_route_history_available', false,
                'explanation', 'WayDrop stores only discrete location points (booking, pickup, dropoff, per security-log event, SOS). No continuous GPS breadcrumb / route history table exists.'),
            'phone_off_status', jsonb_build_object(
                'persisted_evidence_retrievable', true, 'live_location_while_offline', false,
                'explanation', 'All trip/evidence data written during a trip is permanent and retrievable regardless of the device being offline afterwards. Live/current location cannot be obtained while the device is offline; only the last persisted snapshot is available.'),
            'audit', jsonb_build_object('disclosure_id', v_disclosure_id, 'disclosure_recorded', true,
                'admin_log_recorded', v_admin_logged, 'handled_by_context', v_context, 'recorded_at', now())
        );
    END IF;

    SELECT u.* INTO v_user FROM public.users u WHERE u.id = v_target;

    -- ================= SCOPED SECTIONS (built for v_target) =================

    -- identity
    IF 'identity' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        v_identity := jsonb_build_object(
            'user_id',    v_user.id,
            'full_name',  v_user.full_name,
            'phone_full', v_user.phone,
            'email',      v_user.email,
            'user_code',  v_user.user_code,
            'gender',     v_user.gender,
            'created_at', v_user.created_at,
            'deleted_at', v_user.deleted_at,
            'is_rider',   (v_rider_id IS NOT NULL),
            'rider_id',   v_rider_id,
            'profile_photo_path', v_user.profile_photo_url
        );
    END IF;

    -- kyc  (+ dl / pan / aadhaar sub-scopes; + deleted-account archive)
    IF 'kyc' = ANY(v_scope) OR 'dl' = ANY(v_scope) OR 'pan' = ANY(v_scope)
       OR 'aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        SELECT jsonb_build_object(
            'source', 'rider_kyc',
            'kyc_status',        k.kyc_status::text,
            'activation_status', k.activation_status::text,
            'date_of_birth',     k.date_of_birth,
            'father_name',       k.father_name,
            'full_name',         k.full_name,
            'vehicle_type',      k.vehicle_type::text,
            'vehicle_number',    k.vehicle_number,
            'approved_at',       k.approved_at,
            'rejected_at',       k.rejected_at,
            'rejection_reason',  k.rejection_reason,
            'rejection_count',   k.rejection_count,
            'blocked_until',     k.blocked_until,
            'handled_by_admin_id', k.handled_by_admin_id,
            'driving_license_number',
                CASE WHEN 'dl' = ANY(v_scope) OR 'all' = ANY(v_scope)
                     THEN k.driving_license_number ELSE NULL END,
            'pan_number',
                CASE WHEN 'pan' = ANY(v_scope) OR 'all' = ANY(v_scope)
                     THEN k.pan_number ELSE NULL END,
            'aadhaar_number',
                CASE WHEN ('aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope))
                          AND COALESCE(p_legal_review_confirmed,false) = true
                     THEN k.aadhaar_number ELSE NULL END,
            'aadhaar_withheld_reason',
                CASE WHEN ('aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope))
                          AND COALESCE(p_legal_review_confirmed,false) <> true
                     THEN 'scope contains aadhaar but p_legal_review_confirmed is not true'
                     WHEN NOT ('aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope))
                     THEN 'aadhaar not in disclosed_scope'
                     ELSE NULL END
        )
        INTO v_kyc
        FROM public.rider_kyc k WHERE k.user_id = v_target
        LIMIT 1;

        -- deleted-account retention archive (path/number snapshot)
        IF v_kyc IS NULL OR v_deleted THEN
            SELECT jsonb_build_object(
                'source', 'rider_kyc_retention_archive',
                'full_name', a.full_name, 'father_name', a.father_name,
                'date_of_birth', a.date_of_birth,
                'vehicle_type', a.vehicle_type, 'vehicle_number', a.vehicle_number,
                'driving_license_number',
                    CASE WHEN 'dl' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN a.driving_license_number ELSE NULL END,
                'pan_number',
                    CASE WHEN 'pan' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN a.pan_number ELSE NULL END,
                'aadhaar_number',
                    CASE WHEN ('aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope))
                              AND COALESCE(p_legal_review_confirmed,false) = true
                         THEN a.aadhaar_number ELSE NULL END,
                'deletion_requested_at', a.deletion_requested_at,
                'retention_reason', a.retention_reason,
                'retention_expires_at', a.retention_expires_at,
                'legal_hold', a.legal_hold
            )
            INTO v_kyc
            FROM public.rider_kyc_retention_archive a WHERE a.user_id = v_target
            ORDER BY a.created_at DESC LIMIT 1;
        END IF;
        v_kyc := COALESCE(v_kyc, jsonb_build_object('source','none','note','no KYC row and no retention archive for this user'));
    END IF;

    -- kyc_documents (paths always; object metadata + instruction when p_generate_signed_urls)
    IF 'kyc_documents' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        IF COALESCE(p_generate_signed_urls, false) THEN
            BEGIN
                SELECT jsonb_agg(jsonb_build_object(
                    'name', o.name, 'size', (o.metadata->>'size'),
                    'mimetype', (o.metadata->>'mimetype'),
                    'created_at', o.created_at, 'updated_at', o.updated_at))
                INTO v_storage_objs
                FROM storage.objects o
                WHERE o.bucket_id = 'rider_kyc'
                  AND o.name LIKE (v_target::text || '/%');
            EXCEPTION WHEN OTHERS THEN
                v_storage_objs := jsonb_build_object('error',
                    'could not enumerate storage.objects (' || SQLERRM || '); use the paths + signing instruction instead');
            END;
        END IF;

        v_kyc_docs := jsonb_build_object(
            'bucket', 'rider_kyc',
            'bucket_privacy', 'private',
            'paths', (
                SELECT jsonb_strip_nulls(jsonb_build_object(
                    'rider_image', k.rider_image,
                    'aadhaar_front_image', k.aadhaar_front_image,
                    'aadhaar_back_image', k.aadhaar_back_image,
                    'pan_front_image', k.pan_front_image,
                    'pan_back_image', k.pan_back_image,
                    'license_front_image', k.license_front_image,
                    'license_back_image', k.license_back_image,
                    'vehicle_image', k.vehicle_image,
                    'vehicle_rc_front_image', k."VECHILE_RC_front_image",
                    'vehicle_rc_back_image', k."VECHILE_RC_back_image"
                ))
                FROM public.rider_kyc k WHERE k.user_id = v_target LIMIT 1
            ),
            'additional_vehicle_docs', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'rider_vehicle_id', rv.id, 'vehicle_number', rv.vehicle_number,
                    'status', rv.status,
                    'rc_front_image', rv.rc_front_image, 'rc_back_image', rv.rc_back_image,
                    'vehicle_image', rv.vehicle_image))
                FROM public.rider_vehicles rv
                WHERE rv.rider_id = v_rider_id
            ), '[]'::jsonb),
            'archive_paths', (
                SELECT jsonb_strip_nulls(jsonb_build_object(
                    'rider_image_path', a.rider_image_path,
                    'aadhaar_front_image_path', a.aadhaar_front_image_path,
                    'aadhaar_back_image_path', a.aadhaar_back_image_path,
                    'pan_front_image_path', a.pan_front_image_path,
                    'pan_back_image_path', a.pan_back_image_path,
                    'license_front_image_path', a.license_front_image_path,
                    'license_back_image_path', a.license_back_image_path,
                    'vehicle_image_path', a.vehicle_image_path,
                    'vehicle_rc_front_image_path', a.vehicle_rc_front_image_path,
                    'vehicle_rc_back_image_path', a.vehicle_rc_back_image_path))
                FROM public.rider_kyc_retention_archive a WHERE a.user_id = v_target
                ORDER BY a.created_at DESC LIMIT 1
            ),
            'signed_urls', CASE WHEN COALESCE(p_generate_signed_urls,false) THEN
                jsonb_build_object(
                    'note', 'Inline signed-URL generation is not available (the pgsql-http extension is not installed). Generate short-lived signed URLs via: Supabase Dashboard -> Storage -> bucket "rider_kyc" -> open the object -> Copy signed URL; OR the Storage REST API: POST {SUPABASE_URL}/storage/v1/object/sign/rider_kyc/<path> with header Authorization: Bearer <service_role key> and body {"expiresIn": 600}.',
                    'objects_present', v_storage_objs
                )
                ELSE jsonb_build_object('note', 'set p_generate_signed_urls => true for object metadata + signing instructions') END
        );
    END IF;

    -- vehicle
    IF 'kyc' = ANY(v_scope) OR 'vehicle' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        v_vehicle := jsonb_build_object(
            'primary', (
                SELECT jsonb_build_object('vehicle_type', k.vehicle_type::text, 'vehicle_number', k.vehicle_number)
                FROM public.rider_kyc k WHERE k.user_id = v_target LIMIT 1
            ),
            'additional', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id', rv.id, 'vehicle_type', rv.vehicle_type::text, 'vehicle_number', rv.vehicle_number,
                    'status', rv.status, 'reviewed_at', rv.reviewed_at, 'rejection_reason', rv.rejection_reason))
                FROM public.rider_vehicles rv WHERE rv.rider_id = v_rider_id
            ), '[]'::jsonb),
            'rider_profile', (
                SELECT jsonb_build_object('rider_id', r.id, 'account_status', r.account_status::text,
                    'is_verified', r.is_verified, 'service_mode', r.service_mode::text,
                    'rating', r.rating, 'total_orders', r.total_orders,
                    'total_completed_orders', r.total_completed_orders,
                    'total_cancelled_orders', r.total_cancelled_orders, 'created_at', r.created_at)
                FROM public.riders r WHERE r.id = v_rider_id
            )
        );
    END IF;

    -- trips (+ status history + assignment history)  [scope: trips]
    IF 'trips' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        v_pax_trips := COALESCE((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC)
            FROM (
                SELECT o.id AS order_id, o.order_code, o.order_type::text AS order_type,
                       o.order_status::text AS order_status,
                       o.created_at, o.accepted_at, o.rider_arrived_at, o.picked_up_at,
                       o.trip_started_at, o.rider_at_drop_at, o.completed_at, o.cancelled_at,
                       o.cancelled_by::text AS cancelled_by, o.cancel_reason,
                       o.pickup_address, o.pickup_city, o.pickup_lat, o.pickup_lng,
                       o.destination_address, o.destination_city, o.destination_lat, o.destination_lng,
                       o.final_fare, o.current_fare, o.actual_fare, o.gst_amount, o.commission_amount,
                       o.rider_earning, o.payment_mode::text AS payment_mode,
                       o.payment_status::text AS payment_status,
                       o.fare_payment_method::text AS fare_payment_method, o.fare_paid_at,
                       o.vehicle_type::text AS vehicle_type, o.distance_km,
                       o.receiver_name, o.receiver_phone, o.rider_id,
                       o.created_ip_address::text AS created_ip_address,
                       o.created_lat, o.created_lng
                FROM public.orders o WHERE o.user_id = v_target
                ORDER BY o.created_at DESC LIMIT 1000
            ) t
        ), '[]'::jsonb);

        IF v_rider_id IS NOT NULL THEN
            v_rider_trips := COALESCE((
                SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC)
                FROM (
                    SELECT o.id AS order_id, o.order_code, o.order_type::text AS order_type,
                           o.order_status::text AS order_status,
                           o.created_at, o.accepted_at, o.rider_arrived_at, o.picked_up_at,
                           o.trip_started_at, o.rider_at_drop_at, o.completed_at, o.cancelled_at,
                           o.cancelled_by::text AS cancelled_by, o.cancel_reason,
                           o.pickup_address, o.pickup_city, o.pickup_lat, o.pickup_lng,
                           o.destination_address, o.destination_city, o.destination_lat, o.destination_lng,
                           o.final_fare, o.current_fare, o.actual_fare, o.gst_amount, o.commission_amount,
                           o.rider_earning, o.payment_mode::text AS payment_mode,
                           o.payment_status::text AS payment_status,
                           o.fare_payment_method::text AS fare_payment_method, o.fare_paid_at,
                           o.vehicle_type::text AS vehicle_type, o.distance_km,
                           o.receiver_name, o.receiver_phone, o.user_id AS passenger_user_id
                    FROM public.orders o WHERE o.rider_id = v_rider_id
                    ORDER BY o.created_at DESC LIMIT 1000
                ) t
            ), '[]'::jsonb);
        END IF;

        v_status_hist := COALESCE((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at)
            FROM (
                SELECT h.order_id, h.previous_status, h.new_status, h.changed_by,
                       h.changed_by_user_id, h.changed_by_rider_id, h.changed_by_admin_id,
                       h.notes, h.metadata, h.created_at
                FROM public.order_status_history h
                WHERE h.order_id IN (
                    SELECT id FROM public.orders WHERE user_id = v_target
                    UNION SELECT id FROM public.orders WHERE rider_id = v_rider_id
                )
                ORDER BY h.created_at LIMIT 3000
            ) t
        ), '[]'::jsonb);

        IF v_rider_id IS NOT NULL THEN
            v_assign_hist := COALESCE((
                SELECT jsonb_agg(to_jsonb(t) ORDER BY t.sent_at DESC NULLS LAST)
                FROM (
                    SELECT ra.order_id, ra.assignment_round, ra.assignment_status::text AS assignment_status,
                           ra.response_type, ra.distance_km, ra.estimated_earnings, ra.last_seen_fare,
                           ra.sent_at, ra.viewed_at, ra.last_seen_at, ra.responded_at,
                           ra.last_response_at, ra.accepted_at, ra.rejected_at, ra.expires_at, ra.hidden_until
                    FROM public.rider_assignments ra WHERE ra.rider_id = v_rider_id
                    ORDER BY ra.sent_at DESC NULLS LAST LIMIT 3000
                ) t
            ), '[]'::jsonb);
        END IF;
    END IF;

    -- parcel_evidence  [scope: parcel_evidence]
    IF 'parcel_evidence' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        v_parcel_ev := COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'order_id', o.id, 'order_code', o.order_code,
                'order_type', o.order_type::text, 'order_status', o.order_status::text,
                'created_at', o.created_at, 'completed_at', o.completed_at,
                'parcel', jsonb_build_object(
                    'parcel_type', o.parcel_type::text, 'weight_category', o.weight_category,
                    'actual_weight_kg', o.actual_weight_kg, 'declared_value', o.parcel_declared_value,
                    'special_instructions', o.special_instructions, 'high_risk_parcel', o.high_risk_parcel,
                    'sender_declaration_accepted', o.sender_declaration_accepted,
                    'sender_declaration_accepted_at', o.sender_declaration_accepted_at,
                    'pickup_verification_completed', o.pickup_verification_completed,
                    'pickup_verification_completed_at', o.pickup_verification_completed_at),
                'sender', (SELECT jsonb_build_object('user_id', su.id, 'full_name', su.full_name,
                              'phone_last4', right(regexp_replace(COALESCE(su.phone,''),'\D','','g'),4))
                           FROM public.users su WHERE su.id = o.user_id),
                'receiver', jsonb_build_object('name', o.receiver_name, 'phone', o.receiver_phone),
                'addresses', jsonb_build_object(
                    'pickup_address', o.pickup_address, 'pickup_lat', o.pickup_lat, 'pickup_lng', o.pickup_lng,
                    'destination_address', o.destination_address, 'destination_lat', o.destination_lat,
                    'destination_lng', o.destination_lng),
                'parcel_image_paths', to_jsonb(o.parcel_images),
                'parcel_image_bucket', 'parcel_images (public)',
                'verifications', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'verification_type', ov.verification_type, 'verification_status', ov.verification_status,
                        'photo_url', ov.photo_url, 'latitude', ov.latitude, 'longitude', ov.longitude,
                        'created_by', ov.created_by, 'created_at', ov.created_at, 'metadata', ov.metadata))
                    FROM public.order_verifications ov WHERE ov.order_id = o.id), '[]'::jsonb),
                'security_logs', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'event_type', pl.event_type, 'latitude', pl.latitude, 'longitude', pl.longitude,
                        'event_latitude', pl.event_latitude, 'event_longitude', pl.event_longitude,
                        'ip_address', pl.ip_address::text, 'device_id', pl.device_id,
                        'photo_url', pl.photo_url, 'metadata', pl.metadata, 'created_at', pl.created_at)
                        ORDER BY pl.created_at)
                    FROM public.parcel_security_logs pl WHERE pl.order_id = o.id), '[]'::jsonb)
            ) ORDER BY o.created_at DESC)
            FROM public.orders o
            WHERE (o.user_id = v_target OR o.rider_id = v_rider_id)
              AND o.order_type::text LIKE '%parcel%'
            LIMIT 300
        ), '[]'::jsonb);
    END IF;

    -- police_sos  [scope: trips OR parcel_evidence]
    IF 'trips' = ANY(v_scope) OR 'parcel_evidence' = ANY(v_scope) OR 'all' = ANY(v_scope) THEN
        v_sos := COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'order_id', s.order_id, 'rider_id', s.rider_id, 'opened_at', s.opened_at,
                'latitude', s.latitude, 'longitude', s.longitude,
                'rider_lat', s.rider_lat, 'rider_lng', s.rider_lng,
                'police_reference_code', s.police_reference_code,
                'support_ticket_code', s.support_ticket_code, 'notes', s.notes)
                ORDER BY s.opened_at DESC)
            FROM public.police_sos_logs s
            WHERE s.rider_id = v_rider_id
               OR s.order_id IN (
                    SELECT id FROM public.orders WHERE user_id = v_target
                    UNION SELECT id FROM public.orders WHERE rider_id = v_rider_id)
        ), '[]'::jsonb);
    END IF;

    -- last_known_location  [scope: last_known_location]  -- SNAPSHOT ONLY
    IF ('last_known_location' = ANY(v_scope) OR 'all' = ANY(v_scope)) AND v_rider_id IS NOT NULL THEN
        SELECT jsonb_build_object(
            'rider_id', r.id,
            'current_lat', r.current_lat, 'current_lng', r.current_lng, 'heading', r.current_heading,
            'last_location_updated_at', r.last_location_updated_at, 'last_active_at', r.last_active_at,
            'snapshot_not_route', true,
            'note', 'Single last-persisted GPS snapshot (riders table). Overwritten on the next ping; there is no history. rider_locations mirror is identical and holds no history either.'
        )
        INTO v_last_loc
        FROM public.riders r WHERE r.id = v_rider_id;
    END IF;

    -- ---- 5. ASSEMBLE ------------------------------------------------------------
    RETURN jsonb_build_object(
        'request', jsonb_build_object(
            'generated_at', now(),
            'requesting_authority', p_requesting_authority,
            'legal_basis', p_legal_basis,
            'reference_number', p_reference_number,
            'legal_review_confirmed', COALESCE(p_legal_review_confirmed, false),
            'disclosed_scope', to_jsonb(v_scope),
            'phone_input_last4', right(v_ten, 4),
            'notes', NULLIF(btrim(COALESCE(p_notes,'')), '')
        ),
        'matched_users', v_matches,
        'multiple_phone_matches', v_multi,
        'user_not_found', false,
        'detail_target_user_id', v_target,
        'detail_note', CASE WHEN v_multi
            THEN 'multiple users share this normalised phone; detail sections below are for the MOST RECENTLY CREATED match. All matches are in matched_users -- run a targeted query per user_id for others.'
            ELSE NULL END,
        'identity', v_identity,
        'kyc', v_kyc,
        'kyc_documents', v_kyc_docs,
        'vehicle', v_vehicle,
        'rides_as_passenger', v_pax_trips,
        'rides_as_rider', v_rider_trips,
        'status_history', v_status_hist,
        'assignment_history', v_assign_hist,
        'parcel_evidence', v_parcel_ev,
        'police_sos', v_sos,
        'last_known_location', v_last_loc,
        'location_limitations', jsonb_build_object(
            'snapshot_not_route', true,
            'continuous_route_history_available', false,
            'explanation', 'WayDrop persists only discrete location points: order.created_lat/lng (booking), order.pickup_lat/lng and order.destination_lat/lng, order_verifications.latitude/longitude (pickup + dropoff), parcel_security_logs.latitude/longitude + event_latitude/longitude (per event), police_sos_logs coordinates, and riders.current_lat/lng (last snapshot). There is NO continuous GPS breadcrumb / route-history table.'),
        'phone_off_status', jsonb_build_object(
            'persisted_evidence_retrievable', true,
            'live_location_while_offline', false,
            'explanation', 'Every field written during the trip (addresses, coordinates, all *_at timestamps reached, fares, receiver, parcel fields, parcel_images, order_verifications photos + GPS, parcel_security_logs events + GPS + device_id + ip, order_status_history, rider_assignments, police_sos_logs, KYC + documents) is permanent and retrievable regardless of the device being switched off afterwards. Live/current location CANNOT be obtained while the device is offline -- only the last persisted snapshot (last_known_location) is available, and it is overwritten if the device comes back online.'),
        'audit', jsonb_build_object(
            'disclosure_id', v_disclosure_id,
            'disclosure_recorded', true,
            'disclosure_table', 'public.lawful_disclosure_requests (immutable: no UPDATE/DELETE policy)',
            'admin_log_recorded', v_admin_logged,
            'handled_by_admin_id', v_admin_id,
            'handled_by_context', v_context,
            'recorded_at', now())
    );
END;
$function$;


-- Callable by authenticated (self-gated on is_admin()/service-role/console),
-- and service_role. Never anon / PUBLIC.
REVOKE ALL ON FUNCTION public.lawful_disclosure_report(text, text, text, text[], text, boolean, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lawful_disclosure_report(text, text, text, text[], text, boolean, text, boolean) TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.lawful_disclosure_report(text, text, text, text[], text, boolean, text, boolean);
--   ALTER TABLE public.lawful_disclosure_requests ALTER COLUMN handled_by_admin_id SET NOT NULL;  -- only if still 0/NULL-free
-- (No RLS policy, trigger, or other object was changed.)
-- =============================================================================
