-- Migration: create the data_deletion_requests table the (previously orphaned)
-- DataDeletionScreen already writes to.
-- Date: 2026-07-30
--
-- ROOT CAUSE: lib/shared/screens/data_deletion_screen.dart is a fully-built, working account/
-- data-deletion request screen (Google Play mandates an accessible account-deletion path for any
-- app supporting account creation) that was never linked into navigation anywhere -- confirmed via
-- exhaustive grep, zero references outside its own file. It was also never reachable in the first
-- place: its own `supabase.from('data_deletion_requests').insert(...)` call targets a table that
-- does not exist in ANY migration -- confirmed via grep across supabase/migrations/*.sql. Wiring
-- the screen into Settings navigation (separate change) without first creating this table would
-- ship a "Delete My Data" button that fails on every tap.

CREATE TABLE IF NOT EXISTS public.data_deletion_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    requested_at timestamptz NOT NULL DEFAULT now(),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'rejected')),
    processed_at timestamptz,
    processed_by uuid,
    notes text
);

CREATE INDEX IF NOT EXISTS idx_data_deletion_requests_user_id ON public.data_deletion_requests (user_id);

-- Mirrors idx_unique_pending_payment's pattern: a user can have at most one PENDING request at a
-- time -- a duplicate submit (double-tap, or re-visiting the screen before the first request is
-- processed) fails cleanly with a unique-violation rather than creating duplicate pending rows.
CREATE UNIQUE INDEX IF NOT EXISTS idx_one_pending_deletion_request_per_user
    ON public.data_deletion_requests (user_id) WHERE status = 'pending';

ALTER TABLE public.data_deletion_requests ENABLE ROW LEVEL SECURITY;

-- A user may view and create their own requests. No UPDATE/DELETE policy for 'authenticated' --
-- processing a request (status transitions) is an operations/admin action, service_role only.
DROP POLICY IF EXISTS "Users can view their own deletion requests" ON public.data_deletion_requests;
CREATE POLICY "Users can view their own deletion requests"
    ON public.data_deletion_requests
    FOR SELECT TO authenticated
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create their own deletion request" ON public.data_deletion_requests;
CREATE POLICY "Users can create their own deletion request"
    ON public.data_deletion_requests
    FOR INSERT TO authenticated
    WITH CHECK (auth.uid() = user_id);

GRANT SELECT, INSERT ON public.data_deletion_requests TO authenticated;
GRANT ALL ON public.data_deletion_requests TO service_role;
