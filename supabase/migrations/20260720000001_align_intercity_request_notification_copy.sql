-- Migration: Align intercity_requests notification copy to the exact spec wording for
-- Feature 5 (New Travel Request) and Feature 6 (Travel Request Accepted).
-- Date: 2026-07-20
--
-- Base definition: 20260717000009_intercity_notification_copy_and_near_destination.sql. Only two
-- strings change (the sender-initiated INSERT body, and the 'confirmed' title/body sent to the
-- passenger); every other branch (invitation copy, discussion_started, rejected, paid,
-- in_progress, completed, the reject-fallback block, and the rider's own 'confirmed' copy) is
-- preserved byte-for-byte to avoid regressing anything already working.

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

        IF NEW.initiated_by = 'sender' THEN
            -- User pressed "Travel Together" -> Travel Request sent to the Partner (Feature 5)
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Travel Request';
            v_body := 'Someone wants to travel with you. Review the request.';
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
