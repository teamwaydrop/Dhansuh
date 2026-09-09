-- =============================================================================
-- PRE-LAUNCH BLOCKER FIX 4 -- Lawful police / government disclosure workflow
--
-- Ref: docs/OPS_final_readiness_audit_2026-09-09.md  (Part 5)
--      Operational runbook: docs/RUNBOOK_lawful_disclosure.md
--
-- GOAL: a controlled, ADMIN-ONLY workflow for responding to a lawful
--   information request about a phone number, with an immutable audit trail.
--
-- HARD RULES (enforced here):
--   * NO public / anon endpoint. Every function is is_admin()-gated and granted
--     only to authenticated + service_role.
--   * NO authenticated rider/passenger access to any of this.
--   * Phone search is normalized and never stores the full number -- only the
--     last 4 digits are retained on the disclosure record / audit log.
--   * Data retrieval is scoped to ONE target user and their own rides only.
--     It is impossible to page arbitrary records through these functions.
--   * The disclosure event is recorded BEFORE ride history can be pulled
--     (admin_get_disclosure_ride_history requires a disclosure_id).
--   * The disclosure table is immutable to every client role (SELECT-only
--     policy for admins; no INSERT/UPDATE/DELETE policy -> only the
--     SECURITY DEFINER RPC / service_role can write it).
--
-- Admin authorization model = public.is_admin() (email in public.admins AND
-- is_active) -- the SAME model every existing admin_can_* policy uses. This
-- migration introduces NO new admin model.
--
-- NOTE (explicit, per the audit): this is an internal operational/security
-- control, not legal advice. `legal_review_confirmed` is a required, explicit
-- boolean the recording admin must set -- if your organisation requires counsel
-- sign-off before disclosure, that check happens off-system and is attested here.
--
-- Phone storage format (verified in code -- supabase/functions/_shared/
-- customer_phone.ts): Supabase Auth stores the phone-OTP number as E.164 minus
-- the '+' ("919876543210"); public.users.phone mirrors it. Normalisation below
-- matches on the last 10 digits so any stored prefix variant still resolves.
--
-- IDEMPOTENT: guarded CREATE TABLE / policies / CREATE OR REPLACE FUNCTION.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Immutable disclosure record.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lawful_disclosure_requests (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at             timestamptz NOT NULL DEFAULT now(),
    handled_by_admin_id    uuid NOT NULL REFERENCES public.admins(id),
    requesting_authority   text NOT NULL,
    reference_number       text,
    legal_basis            text NOT NULL,
    legal_review_confirmed boolean NOT NULL DEFAULT false,
    target_user_id         uuid REFERENCES public.users(id) ON DELETE SET NULL,
    target_phone_last4     text,
    disclosed_scope        text[] NOT NULL DEFAULT '{}',
    result_summary         text,
    notes                  text
);

COMMENT ON TABLE public.lawful_disclosure_requests IS
    'Immutable audit trail of lawful information disclosures to police / government. '
    'Written only via admin_record_lawful_disclosure() (SECURITY DEFINER) or service_role. '
    'Never stores the full target phone number -- last 4 digits only.';

CREATE INDEX IF NOT EXISTS idx_lawful_disclosure_target_user
    ON public.lawful_disclosure_requests (target_user_id);
CREATE INDEX IF NOT EXISTS idx_lawful_disclosure_created_at
    ON public.lawful_disclosure_requests (created_at DESC);

ALTER TABLE public.lawful_disclosure_requests ENABLE ROW LEVEL SECURITY;

-- Admins may read the trail. No INSERT/UPDATE/DELETE policy => immutable to
-- every client role (identical pattern to public.admin_logs).
DROP POLICY IF EXISTS "lawful_disclosure_admin_select" ON public.lawful_disclosure_requests;
CREATE POLICY "lawful_disclosure_admin_select"
    ON public.lawful_disclosure_requests
    FOR SELECT
    TO authenticated
    USING (public.is_admin());

REVOKE ALL ON public.lawful_disclosure_requests FROM PUBLIC, anon;
GRANT SELECT ON public.lawful_disclosure_requests TO authenticated;
GRANT ALL    ON public.lawful_disclosure_requests TO service_role;


-- -----------------------------------------------------------------------------
-- Internal helper: normalise an Indian phone to bare 10 digits. NULL if it is
-- not resolvable to 10 digits.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._normalize_in_phone_10(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
    SELECT CASE
        WHEN length(regexp_replace(COALESCE(p_raw, ''), '\D', '', 'g')) >= 10
        THEN right(regexp_replace(p_raw, '\D', '', 'g'), 10)
        ELSE NULL
    END;
$function$;


-- -----------------------------------------------------------------------------
-- 2. Phone -> user identity lookup (no ride history here).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_lookup_user_by_phone(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_admin_id uuid;
    v_ten      text;
    v_user     record;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT id INTO v_admin_id
    FROM public.admins WHERE email = (SELECT auth.email()) AND is_active = true LIMIT 1;
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Active admin record not found for caller' USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_ten := public._normalize_in_phone_10(p_phone);
    IF v_ten IS NULL THEN
        RAISE EXCEPTION 'Phone number must contain at least 10 digits' USING ERRCODE = 'check_violation';
    END IF;

    SELECT u.id, u.full_name, u.user_code, u.email, u.phone, u.created_at, u.deleted_at
    INTO v_user
    FROM public.users u
    WHERE right(regexp_replace(u.phone, '\D', '', 'g'), 10) = v_ten
    ORDER BY u.created_at ASC
    LIMIT 1;

    IF v_user.id IS NULL THEN
        RETURN jsonb_build_object('found', false, 'phone_last4', right(v_ten, 4));
    END IF;

    -- Minimal, redacted audit of the lookup itself (last 4 only).
    INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
    VALUES (v_admin_id, 'lawful_lookup', 'users', v_user.id,
            'Lawful-disclosure phone lookup',
            jsonb_build_object('phone_last4', right(v_ten, 4)));

    RETURN jsonb_build_object(
        'found', true,
        'user', jsonb_build_object(
            'id',          v_user.id,
            'full_name',   v_user.full_name,
            'user_code',   v_user.user_code,
            'email',       v_user.email,
            'phone_last4', right(regexp_replace(v_user.phone, '\D', '', 'g'), 4),
            'created_at',  v_user.created_at,
            'deleted_at',  v_user.deleted_at
        ),
        'rider', (
            SELECT jsonb_build_object(
                'rider_id',       r.id,
                'account_status', r.account_status::text,
                'is_verified',    r.is_verified
            )
            FROM public.riders r WHERE r.user_id = v_user.id LIMIT 1
        )
    );
END;
$function$;


-- -----------------------------------------------------------------------------
-- 3. Record a disclosure (must happen before ride history can be pulled).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_record_lawful_disclosure(
    p_target_user_id       uuid,
    p_requesting_authority text,
    p_legal_basis          text,
    p_disclosed_scope      text[],
    p_reference_number     text    DEFAULT NULL,
    p_result_summary       text    DEFAULT NULL,
    p_legal_review_confirmed boolean DEFAULT false,
    p_notes                text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_admin_id   uuid;
    v_phone      text;
    v_disclosure_id uuid;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT id INTO v_admin_id
    FROM public.admins WHERE email = (SELECT auth.email()) AND is_active = true LIMIT 1;
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Active admin record not found for caller' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NULLIF(btrim(COALESCE(p_requesting_authority, '')), '') IS NULL THEN
        RAISE EXCEPTION 'requesting_authority is required' USING ERRCODE = 'check_violation';
    END IF;
    IF NULLIF(btrim(COALESCE(p_legal_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'legal_basis is required' USING ERRCODE = 'check_violation';
    END IF;

    SELECT phone INTO v_phone FROM public.users WHERE id = p_target_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target user % not found', p_target_user_id USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO public.lawful_disclosure_requests (
        handled_by_admin_id, requesting_authority, reference_number, legal_basis,
        legal_review_confirmed, target_user_id, target_phone_last4,
        disclosed_scope, result_summary, notes
    ) VALUES (
        v_admin_id, p_requesting_authority, NULLIF(btrim(COALESCE(p_reference_number,'')),''), p_legal_basis,
        COALESCE(p_legal_review_confirmed, false), p_target_user_id,
        right(regexp_replace(COALESCE(v_phone,''), '\D', '', 'g'), 4),
        COALESCE(p_disclosed_scope, '{}'), NULLIF(btrim(COALESCE(p_result_summary,'')),''),
        NULLIF(btrim(COALESCE(p_notes,'')),'')
    )
    RETURNING id INTO v_disclosure_id;

    INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
    VALUES (v_admin_id, 'lawful_disclosure', 'users', p_target_user_id,
            'Lawful information disclosure recorded',
            jsonb_build_object(
                'disclosure_id', v_disclosure_id,
                'requesting_authority', p_requesting_authority,
                'reference_number', p_reference_number,
                'disclosed_scope', to_jsonb(COALESCE(p_disclosed_scope, '{}')),
                'legal_review_confirmed', COALESCE(p_legal_review_confirmed, false),
                'phone_last4', right(regexp_replace(COALESCE(v_phone,''), '\D', '', 'g'), 4)
            ));

    RETURN jsonb_build_object('success', true, 'disclosure_id', v_disclosure_id);
END;
$function$;


-- -----------------------------------------------------------------------------
-- 4. Scoped ride/identity retrieval for a recorded disclosure.
--    Requires a valid disclosure_id -> data can never be pulled without a
--    recorded, audited disclosure event.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_disclosure_ride_history(p_disclosure_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
-- VOLATILE (default): it writes an admin_logs retrieval-audit row.
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_admin_id  uuid;
    v_target    uuid;
    v_rider_id  uuid;
    v_result    jsonb;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT id INTO v_admin_id
    FROM public.admins WHERE email = (SELECT auth.email()) AND is_active = true LIMIT 1;
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Active admin record not found for caller' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT target_user_id INTO v_target
    FROM public.lawful_disclosure_requests WHERE id = p_disclosure_id;
    IF v_target IS NULL THEN
        RAISE EXCEPTION 'Disclosure % not found or has no target user', p_disclosure_id
            USING ERRCODE = 'no_data_found';
    END IF;

    SELECT id INTO v_rider_id FROM public.riders WHERE user_id = v_target LIMIT 1;

    SELECT jsonb_build_object(
        'disclosure_id', p_disclosure_id,
        'generated_at',  now(),
        'user', (
            SELECT jsonb_build_object(
                'id', u.id, 'full_name', u.full_name, 'user_code', u.user_code,
                'email', u.email,
                'phone_last4', right(regexp_replace(COALESCE(u.phone,''), '\D', '', 'g'), 4),
                'created_at', u.created_at, 'deleted_at', u.deleted_at
            ) FROM public.users u WHERE u.id = v_target
        ),
        'rider_profile', CASE WHEN v_rider_id IS NULL THEN NULL ELSE (
            SELECT jsonb_build_object(
                'rider_id', r.id, 'account_status', r.account_status::text,
                'is_verified', r.is_verified,
                'kyc', (
                    SELECT jsonb_build_object(
                        'full_name', k.full_name, 'father_name', k.father_name,
                        'date_of_birth', k.date_of_birth, 'vehicle_type', k.vehicle_type::text,
                        'vehicle_number', k.vehicle_number, 'kyc_status', k.kyc_status::text
                    ) FROM public.rider_kyc k WHERE k.user_id = v_target LIMIT 1
                )
            ) FROM public.riders r WHERE r.id = v_rider_id
        ) END,
        'rides_as_passenger', COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT o.order_code, o.order_type::text AS order_type, o.order_status::text AS order_status,
                       o.created_at, o.pickup_address, o.pickup_city,
                       o.destination_address, o.destination_city,
                       o.final_fare, o.current_fare, o.fare_payment_method::text AS fare_payment_method,
                       o.payment_status::text AS payment_status,
                       o.receiver_name, o.receiver_phone, o.rider_id
                FROM public.orders o
                WHERE o.user_id = v_target
                ORDER BY o.created_at DESC
                LIMIT 500
            ) t
        ), '[]'::jsonb),
        'rides_as_rider', CASE WHEN v_rider_id IS NULL THEN '[]'::jsonb ELSE COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT o.order_code, o.order_type::text AS order_type, o.order_status::text AS order_status,
                       o.created_at, o.pickup_address, o.pickup_city,
                       o.destination_address, o.destination_city,
                       o.final_fare, o.current_fare, o.fare_payment_method::text AS fare_payment_method,
                       o.payment_status::text AS payment_status, o.user_id AS passenger_user_id
                FROM public.orders o
                WHERE o.rider_id = v_rider_id
                ORDER BY o.created_at DESC
                LIMIT 500
            ) t
        ), '[]'::jsonb) END
    ) INTO v_result;

    -- Audit that the scoped data was actually retrieved for this disclosure.
    INSERT INTO public.admin_logs (admin_id, action_type, target_type, target_id, description, metadata)
    VALUES (v_admin_id, 'lawful_disclosure_retrieval', 'users', v_target,
            'Scoped ride history retrieved for recorded disclosure',
            jsonb_build_object('disclosure_id', p_disclosure_id));

    RETURN v_result;
END;
$function$;


REVOKE ALL ON FUNCTION public._normalize_in_phone_10(text)                                     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_lookup_user_by_phone(text)                                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_record_lawful_disclosure(uuid, text, text, text[], text, text, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_get_disclosure_ride_history(uuid)                          FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_lookup_user_by_phone(text)                              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_record_lawful_disclosure(uuid, text, text, text[], text, text, boolean, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_disclosure_ride_history(uuid)                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._normalize_in_phone_10(text)                                  TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.admin_get_disclosure_ride_history(uuid);
--   DROP FUNCTION IF EXISTS public.admin_record_lawful_disclosure(uuid, text, text, text[], text, text, boolean, text);
--   DROP FUNCTION IF EXISTS public.admin_lookup_user_by_phone(text);
--   DROP FUNCTION IF EXISTS public._normalize_in_phone_10(text);
--   DROP TABLE IF EXISTS public.lawful_disclosure_requests;
-- =============================================================================
