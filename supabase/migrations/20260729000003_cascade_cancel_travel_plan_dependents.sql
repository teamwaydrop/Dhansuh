-- Migration: Cascade a Travel Plan cancellation to its dependent bookings, closing the
-- stale-state bug where a passenger (or the traveller's own other screens) kept seeing a
-- "matched"/"confirmed" traveller after the traveller cancelled the underlying Travel Plan.
-- Date: 2026-07-29
--
-- ROOT CAUSE (confirmed by reading every migration touching rider_travel_plans triggers, plus
-- both client call sites): "delete Travel Plan" in this codebase has always been a soft-cancel
-- status transition (`UPDATE rider_travel_plans SET status = 'cancelled'`), never a hard DELETE --
-- see rider_home_tab.dart's and intercity_bookings_screen.dart's `_deleteTravelPlan`, and the
-- existing `prevent_delete_active_travel_plan` BEFORE DELETE guard (20260617000001), which only
-- ever guards a real DELETE and therefore never fires for this soft-cancel path. No trigger has
-- ever propagated that cancellation to the `intercity_requests` negotiation rows or the `orders`
-- rows tied to this plan. The reverse direction (a passenger cancelling their own order) already
-- propagates correctly today, via update-order-status's existing
-- "SYNC THE LINKED intercity_requests ... TERMINAL STATE" block (20260718000007) -- this migration
-- adds the missing, symmetric traveller -> passenger direction using the same terminal-state
-- convention, not a new one.
--
-- Every passenger-facing screen that needs to reflect this already has a live realtime
-- subscription on `orders` and/or `intercity_requests` (intercity_searching_screen.dart,
-- intercity_tracking_screen.dart via RealtimeOrderController, order_chat_screen.dart,
-- travel_plan_details_screen.dart on the traveller's own other devices/sessions) -- none of that
-- client wiring needs to change; it was simply never given anything to react to. This migration is
-- the single, canonical place that gives it something to react to.
--
-- FIX (two triggers on rider_travel_plans, both scoped to the transition INTO 'cancelled'):
--   1. BEFORE UPDATE guard: refuse to cancel a plan while it still has an in_progress trip -- a
--      live trip must be completed or explicitly handled some other way, never silently orphaned
--      by a plan-level cancel. Mirrors the existing DELETE guard's intent for the soft-cancel path.
--   2. AFTER UPDATE cascade: every still-open negotiation on this plan (request_sent through paid
--      -- deliberately excluding in_progress, which the guard above already forbids, and excluding
--      already-terminal rows: completed/cancelled/rejected/expired, which are settled history and
--      must never be touched) is marked 'cancelled'. Any order that had already reached
--      order_status = 'accepted' under this exact plan/rider is cancelled the same way
--      update-order-status cancels an order (order_status + cancelled_at + cancel_reason +
--      order_status_history row), so the passenger sees a clean terminal "cancelled" state instead
--      of a ghost "accepted" order with a rider who is no longer actually coming.
--
-- Also extends on_intercity_request_change() (base: 20260717000009, last touched
-- 20260729000000_intercity_match_notification_wording_and_dedup.sql, preserved byte-for-byte here
-- except for the one new ELSIF branch) so the passenger gets the same push-notification treatment
-- every other status transition already gets, instead of only a silent realtime UI update.
-- =====================================================================

-- =====================================================================
-- 1. BEFORE UPDATE guard: block cancelling a plan that has a trip already underway.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.guard_travel_plan_cancellation()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN
        IF EXISTS (
            SELECT 1 FROM public.intercity_requests
            WHERE route_id = OLD.id AND status = 'in_progress'
        ) THEN
            RAISE EXCEPTION 'Cannot cancel this travel plan while a trip is already in progress.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_guard_travel_plan_cancellation ON public.rider_travel_plans;
CREATE TRIGGER trigger_guard_travel_plan_cancellation
BEFORE UPDATE ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.guard_travel_plan_cancellation();

-- =====================================================================
-- 2. AFTER UPDATE cascade: cancel dependent intercity_requests + orders.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()
RETURNS TRIGGER AS $$
DECLARE
    v_now timestamptz := now();
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN

        -- Every still-open negotiation/booking on this plan -- never a row already in a terminal
        -- state (completed/cancelled/rejected/expired), and never in_progress (the guard above
        -- already refused the update if one exists).
        UPDATE public.intercity_requests
        SET status = 'cancelled',
            metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('cancelled_reason', 'travel_plan_cancelled'),
            updated_at = v_now
        WHERE route_id = NEW.id
          AND status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');

        -- The underlying order for each request just cancelled above, but only if it's still this
        -- exact plan's own rider and still sitting at 'accepted' (never touches an order that has
        -- already moved past acceptance under some other status, or belongs to a different rider).
        UPDATE public.orders o
        SET order_status = 'cancelled'::public.order_status_enum,
            cancelled_at = v_now,
            cancel_reason = 'Traveller cancelled the travel plan.',
            updated_at = v_now
        FROM public.intercity_requests ir
        WHERE ir.route_id = NEW.id
          AND ir.parcel_id = o.id
          AND ir.status = 'cancelled'
          AND o.order_status = 'accepted'
          AND o.rider_id = NEW.rider_id;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        SELECT o.id, 'accepted', 'cancelled', 'system_travel_plan_cancelled',
               'Cancelled because the linked travel plan was cancelled by the traveller.'
        FROM public.orders o
        WHERE o.rider_id = NEW.rider_id
          AND o.order_status = 'cancelled'
          AND o.cancelled_at = v_now
          AND EXISTS (
              SELECT 1 FROM public.intercity_requests ir
              WHERE ir.route_id = NEW.id AND ir.parcel_id = o.id AND ir.status = 'cancelled'
          );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_cascade_cancel_travel_plan_dependents ON public.rider_travel_plans;
CREATE TRIGGER trigger_cascade_cancel_travel_plan_dependents
AFTER UPDATE ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.cascade_cancel_travel_plan_dependents();

-- =====================================================================
-- 3. on_intercity_request_change(): add the missing 'cancelled' notification branch (every other
--    branch preserved byte-for-byte from 20260729000000).
-- =====================================================================
CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_passenger_user_id uuid := NEW.sender_id;
    v_title text := '';
    v_body text := '';
    v_notify_user_id uuid := NULL;
    v_order_pickup text;
    v_order_dest text;
    v_order_date timestamptz;
    v_sender_name text;
    v_rider_name text;
    v_plan_pickup text;
    v_plan_dest text;
BEGIN
    -- Fetch the rider's user_id
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    -- A) When a request is INSERTED (request_sent)
    IF TG_OP = 'INSERT' THEN
        SELECT pickup_city, destination_city, COALESCE(travel_date, created_at)
        INTO v_order_pickup, v_order_dest, v_order_date
        FROM public.orders WHERE id = NEW.parcel_id;

        SELECT full_name INTO v_sender_name FROM public.users WHERE id = v_passenger_user_id;
        SELECT full_name INTO v_rider_name FROM public.rider_kyc WHERE user_id = v_rider_user_id;

        -- The traveller's OWN Travel Plan route (never the passenger's order fields, which can
        -- legitimately differ slightly in address text even when matching the same plan) -- this
        -- is "your [Origin] -> [Destination] trip" in the notification copy below.
        IF NEW.route_id IS NOT NULL THEN
            SELECT pickup_city, destination_city INTO v_plan_pickup, v_plan_dest
            FROM public.rider_travel_plans WHERE id = NEW.route_id;
        END IF;

        IF NEW.initiated_by = 'sender' THEN
            v_notify_user_id := v_rider_user_id;
            IF v_plan_pickup IS NOT NULL AND v_plan_dest IS NOT NULL THEN
                IF NEW.booking_type = 'parcel' THEN
                    v_title := 'New Parcel Match';
                    v_body := 'A parcel request matches your ' || v_plan_pickup || ' → ' || v_plan_dest || ' trip.';
                ELSE
                    v_title := 'New Travel Match';
                    v_body := 'A passenger matches your ' || v_plan_pickup || ' → ' || v_plan_dest || ' trip.';
                END IF;
            ELSE
                IF NEW.booking_type = 'parcel' THEN
                    v_title := 'New Parcel Match';
                    v_body := 'A parcel request matches your trip. Review the request.';
                ELSE
                    v_title := 'New Travel Match';
                    v_body := 'A passenger matches your trip. Review the request.';
                END IF;
            END IF;
        ELSE
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Travel Invitation';
            v_body := COALESCE(v_rider_name, 'A travel partner') || ' would like to travel with you. Review the invitation.';
        END IF;

    -- B) When request is UPDATED and status changes
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        IF NEW.status = 'discussion_started' THEN
            IF NEW.initiated_by = 'sender' THEN
                v_notify_user_id := v_passenger_user_id;
            ELSE
                v_notify_user_id := v_rider_user_id;
            END IF;
            v_title := 'Discussion Opened 💬';
            v_body := 'The conversation has been accepted. You can now chat and negotiate the fare!';

        ELSIF NEW.status = 'confirmed' THEN
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Travel Request Accepted';
            v_body := 'Your travel request has been accepted.';

        ELSIF NEW.status = 'rejected' THEN
            v_title := 'Travel Request Update';
            v_body := 'Your travel request wasn''t accepted. You can choose another available partner.';
            IF NEW.metadata->>'rejected_by' = 'sender' THEN
                v_notify_user_id := v_rider_user_id;
            ELSIF NEW.metadata->>'rejected_by' = 'traveller' THEN
                v_notify_user_id := v_passenger_user_id;
            END IF;

        ELSIF NEW.status = 'paid' THEN
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';

        ELSIF NEW.status = 'in_progress' THEN
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';

        ELSIF NEW.status = 'completed' THEN
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';

        ELSIF NEW.status = 'cancelled' THEN
            -- New branch (this migration): the traveller-cancelled-their-plan cascade above writes
            -- this exact status transition -- previously silent (no notify branch existed at all
            -- for 'cancelled'), so the passenger only ever found out by noticing the stale UI.
            -- 'rejected_by'/actor-cancelled flows already have their own dedicated branch above and
            -- the fallback block below; this only fires for the plan-cancellation cascade path,
            -- which never touches metadata.rejected_by.
            IF NEW.metadata->>'rejected_by' IS NULL THEN
                v_notify_user_id := v_passenger_user_id;
                v_title := 'Booking Cancelled';
                v_body := 'Your traveller cancelled this trip. Please choose another available partner.';
            END IF;
        END IF;
    END IF;

    -- Send push notification if a target recipient is identified
    IF v_notify_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_notify_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'intercity_request',
                'request_id', NEW.id,
                'order_id', NEW.parcel_id,
                'rider_id', NEW.traveller_id,
                'status', NEW.status
            )
        );
    END IF;

    -- Reject with unknown actor (defensive fallback)
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'rejected'
       AND NEW.metadata->>'rejected_by' IS NULL THEN
        IF v_passenger_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_passenger_user_id, 'Travel Request Update',
                'Your travel request wasn''t accepted. You can choose another available partner.',
                jsonb_build_object('type', 'intercity_request', 'request_id', NEW.id, 'order_id', NEW.parcel_id, 'status', NEW.status)
            );
        END IF;
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id, 'Travel Request Update',
                'Your travel request wasn''t accepted. You can choose another available partner.',
                jsonb_build_object('type', 'intercity_request', 'request_id', NEW.id, 'order_id', NEW.parcel_id, 'status', NEW.status)
            );
        END IF;
    END IF;

    -- In case of final confirmed status, let's also notify the rider.
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Trip Confirmed',
                'Your travel request has been accepted. Your journey is confirmed. You can now coordinate your trip.',
                jsonb_build_object(
                    'type', 'intercity_request',
                    'request_id', NEW.id,
                    'order_id', NEW.parcel_id,
                    'rider_id', NEW.traveller_id,
                    'status', NEW.status
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
