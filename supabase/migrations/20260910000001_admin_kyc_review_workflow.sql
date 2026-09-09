-- =============================================================================
-- PRE-LAUNCH BLOCKER FIX 2 -- Admin KYC review workflow (server side)
--
-- Ref: docs/OPS_final_readiness_audit_2026-09-09.md  (Part 3)
--
-- WHAT ALREADY EXISTS (unchanged by this migration):
--   * public.rider_kyc  -- rows + all document-path columns (bare storage paths
--     into the PRIVATE bucket "rider_kyc"), kyc_status / activation_status enums,
--     handled_by_admin_id (FK -> admins.id), approved_at / rejected_at /
--     activated_at / rejection_reason / rejection_count / blocked_until.
--   * RLS: admin_can_select_rider_kyc  = is_admin()          (SELECT)
--          admin_can_update_rider_kyc  = is_admin()          (UPDATE)
--   * Storage RLS on bucket "rider_kyc": admin_can_select_rider_kyc_storage
--          = (bucket_id = 'rider_kyc' AND is_admin())         (SELECT)
--     -> an admin client can already mint short-lived signed URLs for the doc
--        paths via supabase.storage.from('rider_kyc').createSignedUrl(...).
--   * Trigger trigger_create_rider_profile: WHEN (NEW.kyc_status = 'approved'
--     AND NEW.activation_status = 'active') -> create_rider_profile_on_activation()
--     INSERTs the public.riders row (account_status 'offline', is_verified true).
--   * public.send_push_notification_fnc(user_id, title, body, jsonb)  -- the
--     standard notification path (INSERT notifications -> FCM).
--   * public.admin_logs (immutable: SELECT/INSERT is_admin() only, no UPD/DEL).
--   * public.is_admin()  -- authoritative admin check: email in public.admins
--     AND is_active. (This is the model every admin_can_* policy already uses;
--     this migration adopts the SAME model -- it does NOT introduce a new one.)
--
-- WHAT THIS MIGRATION ADDS:
--   1. admin_list_kyc_queue()          -- read-only; the review inbox.
--   2. admin_review_rider_kyc(kyc_id, decision, rejection_reason)
--                                      -- the single approve/reject entry point:
--        * is_admin() gated
--        * sets the correct rider_kyc columns + timestamps
--        * approve => activation_status 'active' -> existing trigger creates the
--          rider row (this migration does NOT duplicate that logic)
--        * reject  => rejection_reason + rejection_count++ + 7-day block on the
--          2nd rejection (mirrors the existing create-rider-kyc resubmission
--          rule exactly)
--        * writes an admin_logs audit row
--        * fires one notification via the existing send_push_notification_fnc
--
-- NOT TOUCHED: rider_kyc schema, the create_rider_profile trigger, RLS policies,
-- storage policies, create-rider-kyc / validate-rider-kyc Edge Functions, the
-- rider-facing KYC screens, tax logic, ride lifecycle, cron, realtime.
--
-- IDEMPOTENT: CREATE OR REPLACE FUNCTION + guarded GRANT/REVOKE. Re-runnable.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Review inbox (read-only).
--    SECURITY DEFINER so it can join rider_kyc + users behind one is_admin()
--    check without depending on PostgREST embedding. Returns NO document paths
--    or URLs -- the client resolves those separately against storage RLS.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_kyc_queue()
RETURNS TABLE (
    kyc_id             uuid,
    user_id            uuid,
    full_name          text,
    user_code          text,
    phone              text,
    vehicle_type       text,
    vehicle_number     text,
    kyc_status         text,
    activation_status  text,
    rejection_count    integer,
    blocked_until      timestamptz,
    submitted_at       timestamptz,
    updated_at         timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN QUERY
    SELECT
        k.id,
        k.user_id,
        k.full_name,
        u.user_code,
        u.phone,
        k.vehicle_type::text,
        k.vehicle_number,
        k.kyc_status::text,
        k.activation_status::text,
        COALESCE(k.rejection_count, 0),
        k.blocked_until,
        k.created_at,
        k.updated_at
    FROM public.rider_kyc k
    LEFT JOIN public.users u ON u.id = k.user_id
    WHERE k.kyc_status IN ('pending', 'under_review', 'resubmitted')
    ORDER BY k.created_at ASC;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 2. The approve / reject entry point.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_review_rider_kyc(
    p_kyc_id           uuid,
    p_decision         text,
    p_rejection_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_admin_id     uuid;
    v_kyc          public.rider_kyc%ROWTYPE;
    v_new_count    integer;
    v_blocked_until timestamptz;
    v_reason       text;
BEGIN
    -- ---- authorization -----------------------------------------------------
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT id INTO v_admin_id
    FROM public.admins
    WHERE email = (SELECT auth.email()) AND is_active = true
    LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Active admin record not found for caller'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_decision NOT IN ('approve', 'reject') THEN
        RAISE EXCEPTION 'decision must be approve or reject (got %)', p_decision
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- load + validate current state -----------------------------------
    SELECT * INTO v_kyc FROM public.rider_kyc WHERE id = p_kyc_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'KYC record % not found', p_kyc_id USING ERRCODE = 'no_data_found';
    END IF;

    IF v_kyc.kyc_status NOT IN ('pending', 'under_review', 'resubmitted') THEN
        RAISE EXCEPTION 'KYC % is already %; nothing to review', p_kyc_id, v_kyc.kyc_status
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- APPROVE ---------------------------------------------------------
    IF p_decision = 'approve' THEN
        -- activation_status = 'active' is what fires trigger_create_rider_profile,
        -- which is the sole (unchanged) mechanism that creates the riders row.
        UPDATE public.rider_kyc
        SET kyc_status        = 'approved',
            activation_status = 'active',
            handled_by_admin_id = v_admin_id,
            approved_at       = now(),
            activated_at      = now(),
            rejection_reason  = NULL,
            rejected_at       = NULL,
            updated_at        = now()
        WHERE id = p_kyc_id;

        INSERT INTO public.admin_logs (
            admin_id, action_type, target_type, target_id, description, metadata
        ) VALUES (
            v_admin_id, 'kyc_approve', 'rider_kyc', p_kyc_id,
            'KYC approved and partner activated',
            jsonb_build_object('user_id', v_kyc.user_id, 'decision', 'approve')
        );

        PERFORM public.send_push_notification_fnc(
            v_kyc.user_id,
            'Partner verification approved',
            'Your documents have been verified. You can now go online and start accepting rides.',
            jsonb_build_object('type', 'kyc_approved')
        );

        RETURN jsonb_build_object(
            'success', true, 'decision', 'approve', 'kyc_id', p_kyc_id,
            'user_id', v_kyc.user_id
        );
    END IF;

    -- ---- REJECT --------------------------------------------------------
    v_reason := NULLIF(btrim(COALESCE(p_rejection_reason, '')), '');
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'A rejection reason is required' USING ERRCODE = 'check_violation';
    END IF;

    v_new_count := COALESCE(v_kyc.rejection_count, 0) + 1;
    -- Mirror create-rider-kyc/index.ts: 2nd (or later) rejection => 7-day block.
    IF v_new_count >= 2 THEN
        v_blocked_until := now() + interval '7 days';
    ELSE
        v_blocked_until := NULL;
    END IF;

    UPDATE public.rider_kyc
    SET kyc_status        = 'rejected',
        activation_status = 'inactive',
        handled_by_admin_id = v_admin_id,
        rejected_at       = now(),
        rejection_reason  = v_reason,
        rejection_count   = v_new_count,
        blocked_until     = v_blocked_until,
        approved_at       = NULL,
        activated_at      = NULL,
        updated_at        = now()
    WHERE id = p_kyc_id;

    INSERT INTO public.admin_logs (
        admin_id, action_type, target_type, target_id, description, metadata
    ) VALUES (
        v_admin_id, 'kyc_reject', 'rider_kyc', p_kyc_id,
        'KYC rejected: ' || v_reason,
        jsonb_build_object(
            'user_id', v_kyc.user_id, 'decision', 'reject',
            'rejection_reason', v_reason, 'rejection_count', v_new_count,
            'blocked_until', v_blocked_until
        )
    );

    PERFORM public.send_push_notification_fnc(
        v_kyc.user_id,
        'Partner verification needs attention',
        'Your submission was not approved: ' || v_reason ||
        CASE WHEN v_blocked_until IS NOT NULL
             THEN ' You can resubmit after ' || to_char(v_blocked_until AT TIME ZONE 'Asia/Kolkata', 'DD Mon YYYY') || '.'
             ELSE ' Please review and resubmit.' END,
        jsonb_build_object('type', 'kyc_rejected')
    );

    RETURN jsonb_build_object(
        'success', true, 'decision', 'reject', 'kyc_id', p_kyc_id,
        'user_id', v_kyc.user_id, 'rejection_count', v_new_count,
        'blocked_until', v_blocked_until
    );
END;
$function$;


-- -----------------------------------------------------------------------------
-- Grants: callable by any authenticated session; both functions self-enforce
-- is_admin() internally (identical model to the existing admin_can_* policies).
-- Never anon / public.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.admin_list_kyc_queue()                          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_review_rider_kyc(uuid, text, text)        FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_kyc_queue()                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_review_rider_kyc(uuid, text, text)     TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.admin_review_rider_kyc(uuid, text, text);
--   DROP FUNCTION IF EXISTS public.admin_list_kyc_queue();
-- (No schema, policy, trigger, or data change to undo.)
-- =============================================================================
