DROP FUNCTION IF EXISTS public.police_person_details(text, text, text, text, boolean);

CREATE OR REPLACE FUNCTION public.police_person_details(
    p_phone                text,
    p_requesting_authority text DEFAULT 'lawful police disclosure (Supabase SQL editor)',
    p_legal_basis          text DEFAULT 'lawful request - written reference to follow',
    p_reference_number     text DEFAULT NULL
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
    aadhaar_status          text,
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
            p_reference_number, true)
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
        COALESCE(k.aadhaar_number, ar.aadhaar_number),
        CASE WHEN COALESCE(k.aadhaar_number, ar.aadhaar_number) IS NOT NULL
             THEN 'available' ELSE 'not_available' END,
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

REVOKE ALL ON FUNCTION public.police_person_details(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.police_person_details(text, text, text, text) TO authenticated, service_role;
