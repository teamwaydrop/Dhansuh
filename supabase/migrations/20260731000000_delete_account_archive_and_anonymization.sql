-- Migration: Real Delete-Account backend -- legal archive + anonymization RPC.
-- Date: 2026-07-31
--
-- ROOT CAUSE: data_deletion_screen.dart (wired into Settings since 20260730000009) only ever
-- inserts a 'pending' row into public.data_deletion_requests. No edge function, trigger, cron
-- job, or admin screen anywhere in the codebase ever reads that table -- confirmed via exhaustive
-- grep across supabase/functions, supabase/migrations, lib/modules/admin, docs/10_Admin.md and
-- docs/16_Runbook.md. Pressing "Delete My Account" today does not delete, disable, or anonymize
-- anything; the request sits as 'pending' forever.
--
-- This migration adds the pieces a real synchronous delete flow needs:
--   1. public.users.deleted_at -- a queryable "this identity is anonymized" marker. public.users
--      is never hard-deleted (it is the FK anchor for orders/payments/chat/KYC/etc, several of
--      which are ON DELETE RESTRICT precisely to make that impossible -- see
--      20260731000001_fix_deletion_retention_cascades.sql). Deletion = anonymize-in-place.
--   2. public.deleted_user_archive -- a service_role-only legal archive that preserves the
--      original phone/email/name against the stable user_id, for the traveller-protection
--      scenario in the audit: a sender who ships an illegal parcel and then deletes their account
--      must still be identifiable to police/courts via this archive, joined against orders,
--      chats, and parcel evidence which are all retained untouched (this migration never touches
--      orders/payments/order_chat_messages/parcel_security_logs/rider_kyc rows).
--   3. public.delete_user_account() -- the single atomic entry point: archives PII, blanks it out
--      of public.users, and marks the (self-inserted) data_deletion_requests row 'completed'.
--      SECURITY DEFINER, EXECUTE restricted to service_role only -- callable exclusively from the
--      delete-account edge function (which authenticates the caller via their JWT before ever
--      invoking this), never directly by an authenticated client.

-- =====================================================================
-- 1. public.users.deleted_at
-- =====================================================================
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

-- =====================================================================
-- 2. public.deleted_user_archive
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.deleted_user_archive (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- RESTRICT (not CASCADE): the archive must not be able to disappear even if some future
    -- change ever attempted to remove the anchor users row.
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
    deletion_request_id uuid REFERENCES public.data_deletion_requests(id) ON DELETE SET NULL,
    role text,
    original_phone text,
    original_email text,
    original_full_name text,
    deleted_at timestamptz NOT NULL DEFAULT now(),
    deleted_by text NOT NULL DEFAULT 'self_service' CHECK (deleted_by IN ('self_service', 'admin')),
    notes text
);

CREATE INDEX IF NOT EXISTS idx_deleted_user_archive_user_id ON public.deleted_user_archive (user_id);

ALTER TABLE public.deleted_user_archive ENABLE ROW LEVEL SECURITY;

-- Intentionally NO policies for 'authenticated'/'anon' -- default-deny, identical posture to
-- public.admins / public.admin_logs (20260529000000). Only service_role (which bypasses RLS
-- entirely) can ever read the original phone/email/name of a deleted account. This is what makes
-- the archive usable for police/court requests while staying invisible to ordinary users and the
-- mobile app (there is no client code path that queries this table, and none should ever be
-- added -- retrieval is an admin/service_role-only operation by design).
GRANT ALL ON public.deleted_user_archive TO service_role;

-- =====================================================================
-- 3. public.delete_user_account() -- the atomic anonymize+archive entry point
-- =====================================================================
CREATE OR REPLACE FUNCTION public.delete_user_account(
    p_user_id uuid,
    p_deleted_by text DEFAULT 'self_service'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user RECORD;
    v_request_id uuid;
BEGIN
    SELECT id, phone, email, full_name, role, deleted_at
    INTO v_user
    FROM public.users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'delete_user_account: user % does not exist', p_user_id;
    END IF;

    -- Idempotent no-op on retry (e.g. the edge function re-invoking this after the Postgres side
    -- already committed but the subsequent Supabase Auth admin call failed and the client retried)
    -- -- must not re-archive the same identity twice or raise on a legitimate retry.
    IF v_user.deleted_at IS NOT NULL THEN
        RETURN;
    END IF;

    INSERT INTO public.data_deletion_requests (user_id, requested_at, status, processed_at, notes)
    VALUES (
        p_user_id, now(), 'completed', now(),
        'Processed immediately via delete_user_account() -- ' || p_deleted_by
    )
    RETURNING id INTO v_request_id;

    INSERT INTO public.deleted_user_archive (
        user_id, deletion_request_id, role, original_phone, original_email,
        original_full_name, deleted_by
    ) VALUES (
        p_user_id, v_request_id, v_user.role, v_user.phone, v_user.email,
        v_user.full_name, p_deleted_by
    );

    -- Anonymize in place. Never DELETE the row -- orders.user_id (ON DELETE RESTRICT) and
    -- riders/rider_kyc (fixed to RESTRICT in the companion migration) would refuse it anyway for
    -- any user with real activity, but the correct behavior for every user is anonymize, not
    -- attempt-then-fail.
    UPDATE public.users
    SET phone = NULL,
        email = NULL,
        full_name = 'Deleted User',
        profile_photo_url = NULL,
        gender = NULL,
        deleted_at = now()
    WHERE id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_user_account(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_user_account(uuid, text) TO service_role;
