-- Migration: Automatic Traveller Available notification lifecycle + trip-start gating.
-- Date: 2026-07-20
--
-- Adds the plumbing needed for bidirectional "Traveller Available" matching (a newly created
-- Travel Plan surfaces to users with an existing matching Trip, AND a newly created Trip surfaces
-- to users with an existing matching Travel Plan) plus the "Waiting for Travel Day" / "Start Trip"
-- gate so accepting an intercity request never implies navigation should start immediately.

-- =====================================================================
-- 1. travel_matches: idempotency ledger for order<->travel_plan matches.
--    One row per (order_id, plan_id) pair, ever. match-intercity-riders inserts a row the first
--    time a pair is discovered as a match (in either matching direction) and only sends the
--    "Traveller Available" notification when the insert is genuinely new — this is what
--    guarantees the same traveller is never notified twice for the same trip, regardless of how
--    many times the background matching run fires for either side.
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.travel_matches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    plan_id uuid NOT NULL REFERENCES public.rider_travel_plans(id) ON DELETE CASCADE,
    matched_direction text NOT NULL CHECK (matched_direction IN ('order_first', 'plan_first')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (order_id, plan_id)
);

CREATE INDEX IF NOT EXISTS idx_travel_matches_order_id ON public.travel_matches(order_id);
CREATE INDEX IF NOT EXISTS idx_travel_matches_plan_id ON public.travel_matches(plan_id);

ALTER TABLE public.travel_matches ENABLE ROW LEVEL SECURITY;

-- Internal bookkeeping ledger written only by the match-intercity-riders edge function
-- (service_role, bypasses RLS). Participants may read their own match rows (useful for future
-- "why am I seeing this traveller" debugging screens) but nothing may be written by client roles.
DROP POLICY IF EXISTS "Participants can view their own travel matches" ON public.travel_matches;
CREATE POLICY "Participants can view their own travel matches"
ON public.travel_matches
FOR SELECT
TO authenticated
USING (
    EXISTS (SELECT 1 FROM public.orders o WHERE o.id = travel_matches.order_id AND o.user_id = auth.uid())
    OR EXISTS (
        SELECT 1 FROM public.rider_travel_plans tp
        JOIN public.riders r ON r.id = tp.rider_id
        WHERE tp.id = travel_matches.plan_id AND r.user_id = auth.uid()
    )
);

-- =====================================================================
-- 2. orders.trip_started_at: set only when the traveller explicitly presses "Start Trip" on the
--    travel date itself. Distinguishes "Accepted, waiting for travel day" from "trip physically
--    under way" without overloading order_status (which stays 'accepted' throughout the wait).
-- =====================================================================
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS trip_started_at timestamptz;

-- =====================================================================
-- 3. start_intercity_trip(): the ONLY server-side path allowed to move an accepted intercity
--    booking out of "Waiting for Travel Day". Enforces the travel-date gate here (not just in the
--    Flutter UI) so navigation can never start early regardless of client trust.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.start_intercity_trip(
    p_order_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_rider RECORD;
    v_order RECORD;
    v_travel_date_local date;
    v_today_local date;
BEGIN
    SELECT * INTO v_rider FROM public.riders WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Rider profile not found for user.');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Order not found.');
    END IF;

    IF v_order.rider_id IS DISTINCT FROM v_rider.id THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'This trip is not assigned to you.');
    END IF;

    IF NOT (v_order.order_type LIKE 'intercity%' OR (v_order.order_type = 'ride' AND COALESCE(v_order.distance_meters, 0) > 20000)) THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'Start Trip only applies to intercity bookings.');
    END IF;

    IF v_order.order_status IS DISTINCT FROM 'accepted' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Trip is not in an accepted state.');
    END IF;

    IF v_order.trip_started_at IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'code', 'ALREADY_STARTED', 'order_id', v_order.id);
    END IF;

    -- Travel-date gate: navigation/trip-start is only allowed once the travel date has arrived,
    -- compared in IST (the app's operating timezone) rather than UTC so a late-evening UTC
    -- rollover doesn't unlock the button a few hours early/late for Indian users.
    v_travel_date_local := (COALESCE(v_order.travel_date, v_order.created_at) AT TIME ZONE 'Asia/Kolkata')::date;
    v_today_local := (now() AT TIME ZONE 'Asia/Kolkata')::date;

    IF v_travel_date_local > v_today_local THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_DATE_NOT_ARRIVED',
            'message', 'You can start this trip only on the travel date.'
        );
    END IF;

    UPDATE public.orders
    SET trip_started_at = now(),
        updated_at = now()
    WHERE id = v_order.id;

    -- Mirror the trip-start into the linked negotiation row so the existing
    -- on_intercity_request_change 'in_progress' notification copy (unchanged) fires for the
    -- passenger, exactly as the previous client-side "Start Transit" write intended.
    UPDATE public.intercity_requests
    SET status = 'in_progress',
        updated_at = now()
    WHERE parcel_id = v_order.id
      AND traveller_id = v_rider.id
      AND status IN ('confirmed', 'paid');

    RETURN jsonb_build_object('success', true, 'code', 'SUCCESS', 'order_id', v_order.id);
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

GRANT EXECUTE ON FUNCTION public.start_intercity_trip(uuid) TO authenticated;

-- =====================================================================
-- 4. Realtime + push for the new "Traveller Available" notification: notifications already flow
--    through the existing send-push-notification / on_notification_insert pipeline for push
--    delivery. Adding the table to the realtime publication additionally lets any open
--    in-app surface (inbox, unread badge) update live instead of only relying on a fresh fetch.
-- =====================================================================
ALTER TABLE public.notifications REPLICA IDENTITY FULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'notifications'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
    END IF;
END $$;
