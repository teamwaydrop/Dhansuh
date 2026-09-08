-- Migration: Intercity notification copy alignment + near-destination trip notification
-- Date: 2026-07-17
--
-- Updates the copy of the two existing notification triggers that already cover the intercity
-- negotiation (on_intercity_request_change) and generic order lifecycle (on_order_status_update)
-- so it matches the spec's Parts 11/13/14/16/17/18/21 wording, without touching local ride/parcel
-- copy or the underlying state machine. Also adds Part 20's "near destination" notification, which
-- had no precedent anywhere — it piggybacks on the existing rider location write path
-- (public.riders.current_lat/current_lng, written by location_cache_service.dart) rather than
-- creating any new tracking mechanism. There is no live ETA-recompute engine in this codebase, so
-- the 3km distance-to-destination threshold is a documented approximation for "~10 minutes away".

-- 1. on_intercity_request_change: align INSERT (Part 11) / confirmed (Part 13) copy, add a
-- 'rejected' branch (Part 14) that notifies only the opposite party from whoever rejected
-- (reject_intercity_offer() stamps metadata.rejected_by before flipping status).
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
            -- User pressed "Travel Together" -> Travel Request sent to the Partner
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Travel Request';
            v_body := COALESCE(v_sender_name, 'A passenger') || ' wants to travel with you from ' ||
                       COALESCE(v_order_pickup, 'your pickup point') || ' to ' ||
                       COALESCE(v_order_dest, 'your destination') || ' on ' ||
                       to_char(COALESCE(v_order_date, now()), 'DD Mon') || '. Review the request.';
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
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Confirmed';
            v_body := 'Your travel request has been accepted. Your journey is confirmed. You can now coordinate your trip.';

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

    -- In case of final confirmed status, let's also notify the rider (Part 13: notify both)
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

-- 2. on_order_status_update: add intercity-aware copy branches (Parts 16/17/18/21) alongside the
-- unchanged local ride/parcel copy, switched on order_type. Also notifies the rider on completion
-- for intercity trips (Part 21 "notify both"), which the generic version never did (it only ever
-- notified the rider on cancellation).
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
    v_otp text := '';
    v_is_intercity boolean := false;
    v_eta_text text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        v_is_intercity := COALESCE(NEW.order_type LIKE 'intercity%', false);

        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            IF v_is_intercity THEN
                IF NEW.estimated_duration_min IS NOT NULL THEN
                    v_eta_text := to_char(now() + (NEW.estimated_duration_min || ' minutes')::interval, 'HH12:MI AM');
                ELSE
                    v_eta_text := 'shortly';
                END IF;
                v_title := 'Your Partner Started the Trip';
                v_body := 'Your travel partner has started the journey. Please get ready. Estimated arrival: ' || v_eta_text;
            ELSE
                v_title := 'Order Accepted 🚗';
                v_body := 'A rider has accepted your order and is on the way!';
            END IF;
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_otp := COALESCE(NEW.pickup_otp, '');
            IF v_is_intercity THEN
                v_title := 'Partner Arrived';
                v_body := 'Your travel partner has arrived at the pickup point. Please meet them. Share OTP ' || v_otp || ' to begin your trip.';
            ELSIF NEW.order_type = 'ride' THEN
                v_title := 'Your Rider has Arrived! 👋';
                v_body := 'Your rider has arrived. Share OTP ' || v_otp || ' with the rider to start your trip.';
            ELSE
                v_title := 'Rider at Pickup Location 📦';
                v_body := 'Your rider has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';
            END IF;
        ELSIF NEW.order_status = 'picked_up' OR NEW.order_status = 'ongoing' THEN
            IF v_is_intercity THEN
                v_title := 'Journey Started';
                v_body := 'You have been marked onboard. Enjoy your journey.';
            ELSE
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your rider''s live location on the map.';
            END IF;
        ELSIF NEW.order_status = 'rider_at_drop' THEN
            v_otp := COALESCE(NEW.delivery_otp, '');
            v_title := 'Rider Reached Drop-off 📍';
            v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
        ELSIF NEW.order_status = 'completed' OR NEW.order_status = 'delivered' THEN
            IF v_is_intercity THEN
                v_title := 'Trip Completed';
                v_body := 'Thank you for travelling with Way Drop. Hope to see you again.';
            ELSE
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank the rider!';
            END IF;
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled ❌';
            v_body := 'Your order has been cancelled.';
        ELSE
            v_title := 'Order Status Update ℹ️';
            v_body := 'There is a new update on your order. Status is now: ' || NEW.order_status;
        END IF;

        -- Send to passenger
        IF v_title != '' AND v_body != '' AND NEW.user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                NEW.user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', NEW.id,
                    'status', NEW.order_status
                )
            );
        END IF;

        -- 2. Notify Rider if order was cancelled
        IF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    'The order you accepted has been cancelled by the customer.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;

        -- 3. Notify Rider on completion too, for intercity trips (Part 21: "notify both")
        IF v_is_intercity AND (NEW.order_status = 'completed' OR NEW.order_status = 'delivered') AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Trip Completed',
                    'Thank you for travelling with Way Drop. Hope to see you again.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', NEW.order_status
                    )
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

-- 3. Near-destination notification (Part 20) — piggybacks on the existing rider location write
-- path (public.riders.current_lat/current_lng), fires once per order.
ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS near_destination_notified boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.on_rider_location_near_destination()
RETURNS TRIGGER AS $$
DECLARE
    v_order RECORD;
    v_dist_km double precision;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, destination_lat, destination_lng
    INTO v_order
    FROM public.orders
    WHERE rider_id = NEW.id
      AND order_status = 'ongoing'
      AND near_destination_notified = false
      AND order_type LIKE 'intercity%'
      AND destination_lat IS NOT NULL
      AND destination_lng IS NOT NULL
    LIMIT 1;

    IF v_order.id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Same haversine formula already used inline elsewhere in this codebase (e.g. the dispatch
    -- proximity trigger in 20260716000000_fix_dispatch_trigger_self_match_and_weight.sql).
    v_dist_km := 6371 * acos(
        LEAST(GREATEST(
            cos(radians(v_order.destination_lat))
            * cos(radians(NEW.current_lat))
            * cos(radians(NEW.current_lng) - radians(v_order.destination_lng))
            + sin(radians(v_order.destination_lat))
            * sin(radians(NEW.current_lat))
        , -1.0), 1.0)
    );

    -- Distance proxy for "~10 minutes away" — there is no live ETA-recompute engine in this
    -- codebase to do this more precisely (route ETA is only computed once at booking time).
    IF v_dist_km <= 3.0 THEN
        UPDATE public.orders
        SET near_destination_notified = true
        WHERE id = v_order.id;

        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Almost There',
            'You are about 10 minutes away from your destination.',
            jsonb_build_object('type', 'trip_near_destination', 'order_id', v_order.id)
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_near_destination_check ON public.riders;
CREATE TRIGGER trigger_near_destination_check
AFTER UPDATE OF current_lat, current_lng ON public.riders
FOR EACH ROW
EXECUTE FUNCTION public.on_rider_location_near_destination();
