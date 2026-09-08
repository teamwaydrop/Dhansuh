-- =====================================================================
-- Account Deletion: server-authoritative anonymization RPC.
-- =====================================================================
-- ARCHITECTURE (audited before writing this migration):
--   - data_deletion_requests (20260730000009) already exists as the compliance audit-log
--     table for this feature -- reused here as the completion marker / idempotency guard,
--     rather than duplicating a new tracking column on public.users.
--   - orders.user_id has ON DELETE RESTRICT (20260529000000) -- so public.users can NEVER be
--     hard-deleted for any account with order history (the vast majority of real accounts),
--     and public.users.id itself has ON DELETE CASCADE FROM auth.users, meaning even
--     attempting to delete the auth.users row would be rejected by the RESTRICT the moment
--     Postgres tries to cascade into public.users. This is why this design anonymizes
--     public.users/riders/rider_kyc/orders IN PLACE rather than deleting rows, and the
--     accompanying edge function bans + revokes sessions for the auth user instead of
--     deleting it.
--   - Confirmed via schema audit which tables to hard-delete vs anonymize vs leave untouched
--     -- see the delete-account edge function's own header comment for the full table-by-table
--     rationale (this function only performs the actual DB mutations; storage + auth admin
--     side effects live in the edge function, which is the only place with the credentials to
--     perform them).
--
-- SECURITY: identity is derived exclusively from auth.uid() -- there is no user_id parameter
-- at all, so this can never be called (even by mistake, even with a crafted request) to act on
-- anyone other than the currently authenticated caller. SECURITY DEFINER is required only to
-- bypass RLS across the many tables touched here (the same pattern already used by every other
-- multi-table RPC in this schema, e.g. accept_intercity_request); it is NOT what makes this
-- safe -- auth.uid() binding is what makes it safe.
--
-- IDEMPOTENCY: checks data_deletion_requests for an existing 'completed' row first and
-- short-circuits; a genuine concurrent double-call is additionally guarded by the existing
-- partial unique index on data_deletion_requests (one 'pending' row per user), and every
-- mutation below is a plain SET-to-constant (never an increment/append), so even an unguarded
-- re-run would be harmless.
-- =====================================================================
--
-- RECONCILIATION NOTE (2026-08-04): applied directly to the linked Supabase project but never
-- committed to this repo; reconstructed verbatim from supabase_migrations.schema_migrations.
-- SUPERSEDED (see 20260803000000_kyc_evidence_retention_on_deletion.sql, applied the next day):
-- that migration replaces this function body with one that archives rider identity evidence
-- before anonymizing it. Both are reconstructed here, in original chronological order, so local
-- migration history matches production's actual applied sequence exactly.

CREATE OR REPLACE FUNCTION public.delete_own_account()
RETURNS jsonb AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_rider RECORD;
    v_already_deleted boolean := false;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHENTICATED', 'message', 'Not authenticated.');
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.data_deletion_requests
        WHERE user_id = v_user_id AND status = 'completed'
    ) INTO v_already_deleted;

    IF v_already_deleted THEN
        RETURN jsonb_build_object('success', true, 'already_deleted', true, 'had_rider_profile', false, 'rider_id', NULL);
    END IF;

    INSERT INTO public.data_deletion_requests (user_id, status)
    VALUES (v_user_id, 'pending')
    ON CONFLICT (user_id) WHERE status = 'pending' DO NOTHING;

    -- =====================================================
    -- RIDER / DROP PARTNER DATA (only if this account ever completed rider onboarding)
    -- =====================================================
    SELECT * INTO v_rider FROM public.riders WHERE user_id = v_user_id;

    IF FOUND THEN
        -- rider_kyc: constraint-safe placeholders (aadhaar/pan/dob have CHECK constraints;
        -- most columns are NOT NULL, so NULL is not usable here -- the placeholder values below
        -- satisfy every constraint on this table while carrying no real personal data).
        UPDATE public.rider_kyc
        SET full_name = 'Deleted User',
            father_name = 'Deleted User',
            aadhaar_number = '000000000000',
            pan_number = 'ZZZZZ0000Z',
            driving_license_number = 'DELETED',
            vehicle_number = 'DELETED',
            date_of_birth = '1900-01-01',
            rider_image = '',
            aadhaar_front_image = '',
            aadhaar_back_image = '',
            pan_front_image = '',
            pan_back_image = '',
            license_front_image = '',
            license_back_image = '',
            vehicle_image = '',
            "VECHILE_RC_front_image" = NULL,
            "VECHILE_RC_back_image" = NULL,
            activation_status = 'suspended',
            rejection_reason = NULL,
            updated_at = now()
        WHERE user_id = v_user_id;

        -- riders: wallet/earnings/rating/order-count numbers are preserved (financial/reliability
        -- history) -- only location and dispatch-eligibility are cleared. 'blocked' permanently
        -- excludes this row from every dispatch/matching query, which all filter on
        -- account_status = 'online'.
        UPDATE public.riders
        SET current_lat = NULL,
            current_lng = NULL,
            current_heading = NULL,
            last_location_updated_at = NULL,
            account_status = 'blocked',
            updated_at = now()
        WHERE user_id = v_user_id;

        -- Financial-identity (bank/UPI) and extra-vehicle records: no historical/ledger value of
        -- their own (the actual payout amounts live in wallet_transactions/rider_withdrawals,
        -- untouched below) -- safe to hard-delete outright.
        DELETE FROM public.rider_payout_accounts WHERE rider_id = v_rider.id;
        DELETE FROM public.rider_vehicles WHERE rider_id = v_rider.id;
    END IF;

    -- =====================================================
    -- PERSONAL / SESSION DATA (no financial or dispute significance) -- hard delete
    -- =====================================================
    DELETE FROM public.notifications WHERE user_id = v_user_id;
    DELETE FROM public.user_devices WHERE user_id = v_user_id;
    DELETE FROM public.user_device_tokens WHERE user_id = v_user_id;

    -- =====================================================
    -- ORDERS: this account's OWN bookings only (as passenger, via user_id) -- fare/GST/
    -- commission/status/timestamps are financial/accounting history and are never touched.
    -- Orders where this account was the assigned RIDER are not re-touched here -- the rider's
    -- own identity was already anonymized above via rider_kyc/riders.
    -- =====================================================
    UPDATE public.orders
    SET pickup_address = 'Deleted',
        destination_address = 'Deleted',
        receiver_name = NULL,
        receiver_phone = NULL,
        special_instructions = NULL,
        created_ip_address = NULL,
        created_device_ref = NULL,
        created_device_model = NULL,
        created_device_brand = NULL,
        created_os_version = NULL,
        created_app_version = NULL
    WHERE user_id = v_user_id;

    -- =====================================================
    -- users: the account row itself. Never deleted (orders.user_id ON DELETE RESTRICT) --
    -- phone/email cleared (both are UNIQUE) so the same phone number can be used to sign up
    -- again in future; notification preferences flipped off as defense-in-depth (device tokens
    -- are already gone, and the auth user is banned by the edge function next).
    -- =====================================================
    UPDATE public.users
    SET full_name = 'Deleted User',
        email = NULL,
        phone = NULL,
        gender = NULL,
        profile_photo_url = NULL,
        pref_order_notifications = false,
        pref_chat_notifications = false,
        pref_rating_notifications = false,
        pref_admin_notifications = false
    WHERE id = v_user_id;

    UPDATE public.data_deletion_requests
    SET status = 'completed', processed_at = now()
    WHERE user_id = v_user_id AND status = 'pending';

    RETURN jsonb_build_object(
        'success', true,
        'already_deleted', false,
        'had_rider_profile', (v_rider.id IS NOT NULL),
        'rider_id', v_rider.id
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'DELETE_FAILED', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.delete_own_account() TO authenticated;
