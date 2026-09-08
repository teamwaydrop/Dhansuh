-- Fix: two more objects from the 2026-07-16 security-audit batch that were marked "applied" in
-- migration history but never actually took effect on the live database (same drift pattern as
-- send_push_notification_fnc, fixed in 20260718000002).
--
-- Verified live via pg_policy / pg_proc introspection against the linked project before writing
-- this migration:
--   1. public.intercity_requests still had only the ORIGINAL single "FOR ALL" policy
--      ("Allow request participants to read/write" from 20260603000001) — the narrower
--      three-policy split from 20260716000004_narrow_intercity_requests_direct_write_policy.sql
--      (SELECT / INSERT restricted to safe initial statuses / UPDATE restricted to safe
--      transitions, confirmed/paid/completed excluded) was never applied. Under the live policy,
--      any participant (sender or traveller) could UPDATE status directly to 'confirmed' / 'paid'
--      / 'completed' from the client, bypassing accept_intercity_offer's/confirm_intercity_booking's
--      capacity and weight checks entirely.
--   2. public.accept_intercity_offer was still SECURITY INVOKER with no participant check and no
--      SET search_path — the original 20260617000001 body, not the SECURITY DEFINER + explicit
--      v_is_participant version from 20260716000004 (finished with SET search_path = public in
--      20260716000008_enforce_travel_plan_weight_capacity.sql, which is confirmed already live and
--      unchanged here).
--
-- These two must land together: accept_intercity_offer's only direct UPDATEs move status to
-- 'discussion_started' or 'fare_agreed', and the new narrower UPDATE policy's WITH CHECK only
-- allows a client-writable subset of statuses directly — 'fare_agreed' is deliberately NOT in that
-- list, so a SECURITY INVOKER accept_intercity_offer would have its own UPDATE rejected by the very
-- RLS it doesn't bypass. Redefining it SECURITY DEFINER (as this migration does, matching
-- 20260716000004/20260716000008 verbatim) is what allows it to still write 'fare_agreed' after the
-- narrower policy is in place, with the participant check inside the function compensating for the
-- RLS bypass so authorization is never actually loosened.
--
-- public.reject_intercity_offer and public.confirm_intercity_booking were both already verified
-- live-correct (SECURITY DEFINER, participant check, SET search_path) via a prior migration
-- (20260717000005 / 20260716000008) and are intentionally left untouched here.
--
-- DEVIATION FROM 20260716000004's original text (found by re-grepping every current
-- intercity_requests call site before applying this, not just trusting that migration's now-stale
-- inventory comment): lib/modules/chat/screens/order_chat_screen.dart's _payBooking() does a direct
-- client UPDATE of status -> 'paid' (order_chat_screen.dart:625-631), and _confirmHandover()
-- (order_chat_screen.dart:653-665) does a metadata-only UPDATE while status is already 'paid'. RLS
-- WITH CHECK re-validates the *entire* new row including unchanged columns, so a metadata-only
-- update still requires the row's current status to be in the allowed set. Neither of these existed
-- (or were reviewed) when 20260716000004 was originally authored; its allowed set of
-- ('request_sent','discussion_started','in_progress') would silently break both of these currently
-- working flows. 'paid' is added to the allowed set below to match today's real call sites. This
-- does not reopen the vulnerability the original migration closed: 'confirmed' (the
-- capacity/weight-checked, RPC-only transition) and 'completed' remain excluded from direct client
-- writes; only 'paid' — which today's app already reaches via an unrestricted direct write with no
-- special server-side gating beyond participant identity — is added, so this is not a new privilege
-- versus current production, just a narrower version of it.

-- 1. Drop the stale single FOR ALL policy.
DROP POLICY IF EXISTS "Allow request participants to read/write" ON public.intercity_requests;

-- 2. SELECT: unchanged participant visibility.
DROP POLICY IF EXISTS "Allow request participants to view requests" ON public.intercity_requests;
CREATE POLICY "Allow request participants to view requests" ON public.intercity_requests
FOR SELECT TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
);

-- 3. INSERT: participant predicate, restricted to the safe initial statuses and leaving the
-- legacy confirmation flags at their default.
DROP POLICY IF EXISTS "Allow request participants to create requests" ON public.intercity_requests;
CREATE POLICY "Allow request participants to create requests" ON public.intercity_requests
FOR INSERT TO authenticated
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid()
        )
    )
    AND status IN ('request_sent', 'discussion_started')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 4. UPDATE: participant predicate, restricted to the specific safe direct transitions/columns.
-- Confirmation ('confirmed'/'paid'/'completed') must go through accept_intercity_offer()/
-- confirm_intercity_booking() (both SECURITY DEFINER, both bypass this policy for their own writes).
DROP POLICY IF EXISTS "Allow request participants to update safe fields" ON public.intercity_requests;
CREATE POLICY "Allow request participants to update safe fields" ON public.intercity_requests
FOR UPDATE TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
)
WITH CHECK (
    (
        sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = traveller_id AND r.user_id = auth.uid()
        )
    )
    AND status IN ('request_sent', 'discussion_started', 'in_progress', 'paid')
    AND sender_confirmed = false
    AND traveller_confirmed = false
);

-- 5. Redefine accept_intercity_offer as SECURITY DEFINER with an explicit participant check
-- (previously provided implicitly by the now-removed permissive RLS policy), and SET search_path.
CREATE OR REPLACE FUNCTION public.accept_intercity_offer(
    p_request_id uuid,
    p_actor_type text
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_metadata jsonb;
    v_is_participant boolean;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    SELECT (
        v_request.sender_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = v_request.traveller_id AND r.user_id = auth.uid()
        )
    ) INTO v_is_participant;

    IF NOT v_is_participant THEN
        RAISE EXCEPTION 'Not authorized to act on this request';
    END IF;

    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb);

    IF p_actor_type = 'sender' THEN
        v_metadata := v_metadata || '{"sender_agreed": true}'::jsonb;
    ELSIF p_actor_type = 'traveller' THEN
        v_metadata := v_metadata || '{"traveller_agreed": true}'::jsonb;
    ELSE
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;

    IF COALESCE((v_metadata->>'sender_agreed')::boolean, false) = true
       AND COALESCE((v_metadata->>'traveller_agreed')::boolean, false) = true THEN
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'fare_agreed',
            updated_at = now()
        WHERE id = p_request_id;
    ELSE
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'discussion_started',
            updated_at = now()
        WHERE id = p_request_id;
    END IF;

    SELECT json_build_object(
        'id', id,
        'status', status,
        'metadata', metadata,
        'proposed_fare', proposed_fare
    )::jsonb INTO v_metadata
    FROM public.intercity_requests
    WHERE id = p_request_id;

    RETURN v_metadata;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
