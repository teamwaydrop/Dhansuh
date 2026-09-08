-- Migration: Schedule + notify on intercity auto-expiry (Part 25)
-- Date: 2026-07-17
--
-- public.expire_stale_intercity_requests() (20260617000001_intercity_workflow_updates.sql) already
-- implemented the exact expiry rules the spec asks for (24h negotiation timeout, travel-date-passed
-- plan expiry) but was never scheduled anywhere — grepping every migration found only one active
-- pg_cron job ('rider-dormant-and-expiry-checks', unrelated). It also never notified anyone; it
-- just flipped status columns. This migration (a) makes it notify both sides using the existing
-- send_push_notification_fnc pipe (same one every other trigger in the app uses), and (b) schedules
-- it every 15 minutes using the exact guarded cron.schedule pattern already used for the dormant-rider
-- job in 20260602000003_expand_notifications_logic.sql.

CREATE OR REPLACE FUNCTION public.expire_stale_intercity_requests()
RETURNS VOID AS $$
DECLARE
    v_req RECORD;
    v_plan RECORD;
    v_traveller_user_id uuid;
BEGIN
    -- Stale negotiation expiration (24h) — notify both the passenger (sender) and the partner
    -- (traveller) that the negotiation timed out.
    FOR v_req IN
        UPDATE public.intercity_requests
        SET status = 'expired',
            expiry_reason = 'negotiation_timeout',
            updated_at = now()
        WHERE status IN ('request_sent', 'discussion_started', 'fare_agreed')
          AND expires_at < now()
        RETURNING id, sender_id, traveller_id, parcel_id
    LOOP
        IF v_req.sender_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_req.sender_id,
                'Travel Request Expired',
                'Your travel request wasn''t accepted in time. You can choose another available partner.',
                jsonb_build_object('type', 'travel_request_expired', 'request_id', v_req.id, 'order_id', v_req.parcel_id)
            );
        END IF;

        SELECT user_id INTO v_traveller_user_id FROM public.riders WHERE id = v_req.traveller_id;
        IF v_traveller_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_traveller_user_id,
                'Travel Request Expired',
                'A pending travel request negotiation has expired without confirmation.',
                jsonb_build_object('type', 'travel_request_expired', 'request_id', v_req.id, 'order_id', v_req.parcel_id)
            );
        END IF;
    END LOOP;

    -- Travel plan auto-expiry — notify the partner whose plan expired.
    FOR v_plan IN
        UPDATE public.rider_travel_plans
        SET status = 'expired'::public.travel_plan_status_enum
        WHERE travel_date < now()
          AND status = 'active'::public.travel_plan_status_enum
        RETURNING id, rider_id
    LOOP
        SELECT user_id INTO v_traveller_user_id FROM public.riders WHERE id = v_plan.rider_id;
        IF v_traveller_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_traveller_user_id,
                'Travel Plan Expired',
                'Your travel plan has expired since its travel date has passed.',
                jsonb_build_object('type', 'travel_plan_expired', 'plan_id', v_plan.id)
            );
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'intercity-expiry-checks',
            '*/15 * * * *', -- every 15 minutes
            'SELECT public.expire_stale_intercity_requests();'
        );
    END IF;
END $$;
