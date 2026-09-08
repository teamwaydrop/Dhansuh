-- Migration: Correct wording for the traveller-facing "New Travel Match" notification, and add a
-- DB-level guard against duplicate active requests creating duplicate notifications.
-- Date: 2026-07-29
--
-- CONTEXT: on_intercity_request_change() (base definition: 20260717000009, last touched
-- 20260720000001_align_intercity_request_notification_copy.sql) already sends a real push
-- notification when a passenger/parcel sends a "Travel Together" request to a traveller (the
-- underlying push-delivery pipeline was a separate bug, already fixed by
-- 20260718000002_fix_stale_send_push_notification_fnc.sql). The remaining gap: the copy is generic
-- ("New Travel Request" / "Someone wants to travel with you") and never names the traveller's own
-- route or distinguishes a passenger match from a parcel match -- exactly the ambiguity the task
-- calls out ("Do not say 'traveller matched' to the traveller if the matched entity is actually a
-- passenger/request"). Every other branch (invitation copy, discussion_started, confirmed,
-- rejected, paid, in_progress, completed, the reject-fallback block, and the rider's own
-- 'confirmed' copy) is preserved byte-for-byte to avoid regressing anything already working.
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
            -- User pressed "Travel Together" -> Travel Request sent to the Partner (Feature 5).
            -- Root-cause fix: this previously read "Someone wants to travel with you" regardless
            -- of whether a passenger or a parcel matched, and never named the traveller's own
            -- route -- ambiguous exactly as flagged ("do not say traveller matched to the
            -- traveller"). Now distinguishes ride vs parcel and names the plan's route whenever
            -- it's known; falls back to the previous generic copy only if the plan's cities are
            -- unavailable (e.g. a plan deleted between insert and trigger -- should not happen in
            -- practice, but never raise/block the request over missing display text).
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
            -- Partner pressed "Travel Together" -> invitation sent to the User
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
            -- Feature 6: Traveller Accept -> booking confirmed, exact spec copy for the passenger.
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
            -- Passenger paid, notify traveller (rider)
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';

        ELSIF NEW.status = 'in_progress' THEN
            -- Trip started, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';

        ELSIF NEW.status = 'completed' THEN
            -- Completed, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';
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

    -- Reject with unknown actor (defensive fallback, e.g. any future code path that sets
    -- status='rejected' without stamping metadata.rejected_by): notify both sides rather than
    -- silently notifying neither.
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

    -- In case of final confirmed status, let's also notify the rider (Part 13: notify both).
    -- Rider-facing copy is unchanged (Feature 6 only specifies the passenger-facing copy above).
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

-- =====================================================================
-- DEDUP GUARD: intercity_matching_service.dart's sendTravelTogetherRequest() already checks for
-- an existing intercity_requests row scoped to (parcel_id, traveller_id) before inserting a new
-- one (see that file) -- but that check-then-insert is not atomic, so a double-tap or client
-- retry landing within the same round trip could still race past it, INSERT a second row for the
-- exact same order+traveller pair, and fire on_intercity_request_change() a second time -- sending
-- the traveller two "New Travel Match" notifications for what is, from their perspective, one
-- event. This makes that SAME existing (parcel_id, traveller_id) predicate an atomic DB-level
-- guard (mirroring idx_unique_pending_payment's pattern elsewhere in this codebase) instead of
-- introducing any new restriction -- it does not block a sender from sending separate requests
-- for a different order to the same traveller/plan, only a second row for the identical
-- order+traveller pair. Terminal statuses are excluded so a legitimately new request after a
-- prior one on the same order/traveller ended (rejected/cancelled/expired/completed) is never
-- blocked.
-- =====================================================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_intercity_requests_one_active_per_order_traveller
    ON public.intercity_requests (parcel_id, traveller_id)
    WHERE status NOT IN ('cancelled', 'rejected', 'expired', 'completed');
