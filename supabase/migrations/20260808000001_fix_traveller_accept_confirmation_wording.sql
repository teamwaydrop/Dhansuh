-- Fix: on_intercity_request_change() sent the traveller (accepting partner) a "Trip Confirmed"
-- notification whose body read "Your travel request has been accepted." -- copy written for the
-- passenger's own confirmation branch (NEW.status = 'confirmed' -> v_passenger_user_id, a few lines
-- above in the same function) and mistakenly reused for the trailing traveller-facing block. The
-- traveller did not have a request accepted -- they are the one who just accepted it -- so the
-- routing was already correct (only the traveller is notified in this block; the passenger is
-- notified once via the earlier v_passenger_user_id branch, so no duplicate exists), but the wording
-- falsely implied the traveller had made a request. This migration changes ONLY that body text.
-- Function body is otherwise byte-for-byte identical to the version deployed in
-- 20260806000000_fix_intercity_parcel_start_trip_notification_wording.sql.

CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    IF TG_OP = 'INSERT' THEN
        SELECT pickup_city, destination_city, COALESCE(travel_date, created_at)
        INTO v_order_pickup, v_order_dest, v_order_date
        FROM public.orders WHERE id = NEW.parcel_id;

        SELECT full_name INTO v_sender_name FROM public.users WHERE id = v_passenger_user_id;
        SELECT full_name INTO v_rider_name FROM public.rider_kyc WHERE user_id = v_rider_user_id;

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
            -- Root-cause fix (this migration): traveller pressed Start Trip -- a plan-level action,
            -- not a per-parcel pickup confirmation. Never claim the parcel was collected here.
            v_notify_user_id := v_passenger_user_id;
            IF NEW.booking_type = 'parcel' THEN
                v_title := 'Trip Started 🚚';
                v_body := E'Your traveller has started the trip with your parcel.\n\nTrack it live in the WayDrop app.';
            ELSE
                v_title := 'Trip Started 🚗';
                v_body := E'Your traveller has started the trip.\n\nTrack the live journey in the WayDrop app.';
            END IF;

        ELSIF NEW.status = 'completed' THEN
            v_notify_user_id := v_passenger_user_id;
            IF NEW.booking_type = 'parcel' THEN
                v_title := 'Parcel Delivered 🎉';
                v_body := E'Your parcel has been delivered successfully.\n\nThank you for choosing WayDrop.';
            ELSE
                v_title := 'Ride Completed 🎉';
                v_body := E'Your ride has been completed successfully.\n\nThank you for choosing WayDrop.';
            END IF;

        ELSIF NEW.status = 'cancelled' THEN
            IF NEW.metadata->>'rejected_by' IS NULL THEN
                v_notify_user_id := v_passenger_user_id;
                v_title := 'Booking Cancelled';
                v_body := 'Your traveller cancelled this trip. Please choose another available partner.';
            END IF;
        END IF;
    END IF;

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

    -- FIX (this migration): this block notifies the TRAVELLER (routing was already correct -- the
    -- passenger's own "Travel Request Accepted" notification is sent separately above via
    -- v_notify_user_id/v_passenger_user_id, so this is not a duplicate). Only the body text changes:
    -- it previously read "Your travel request has been accepted." which falsely told the accepting
    -- traveller that THEIR request had been accepted, when they are the one who just accepted
    -- someone else's request. Wording now correctly addresses the accepting partner.
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Booking Confirmed',
                'You''ve accepted this trip. It''s now confirmed -- coordinate the pickup with your passenger.',
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
$function$;
