-- Migration: Issue 5 (Phase 2) -- when a Traveller deletes/cancels their entire Travel Plan, the
-- User correctly receives the "Travel Plan Cancelled" notification, but tapping it opened
-- NotificationDetailScreen with an "Open Chat" button. A travel-plan deletion is not a chat
-- message and the negotiation this order's chat channel belonged to has ended -- Chat must not be
-- offered as an action for it.
--
-- ROOT CAUSE: NotificationDetailScreen._canOpenChat only ever checked whether `order_id` was
-- present in the tap payload. Every 'intercity_request' notification (match, invitation,
-- discussion, confirmed, paid, in_progress, completed, AND every flavor of 'cancelled') carries
-- `order_id` (NEW.parcel_id) in its payload -- so the check could never distinguish a genuine,
-- still-relevant negotiation from one that had just been terminated by a whole-plan deletion. The
-- payload had no field at all identifying WHICH kind of cancellation this was; the client had
-- nothing reliable to check.
--
-- Traced end to end: rider taps "Delete Plan" (travel_plan_details_screen.dart) ->
-- cancel_travel_plan_by_traveller() -> UPDATE rider_travel_plans SET status='cancelled' ->
-- cascade_cancel_travel_plan_dependents() (AFTER UPDATE trigger, 20260901000001) tags every
-- affected intercity_requests row with metadata->>'cancelled_scope' = 'travel_plan' and sets
-- status='cancelled' -> on_intercity_request_change() (AFTER UPDATE on intercity_requests) sees
-- NEW.metadata->>'cancelled_scope' = 'travel_plan', sends the already-correct "Travel Plan
-- Cancelled" title/body (20260901000002/20260901000024, unchanged) -- but the jsonb payload handed
-- to send_push_notification_fnc() (and therefore stored in notifications.payload, and therefore
-- reaching NotificationDetailScreen's tapData both from a real push tap and from the in-app inbox)
-- never included cancelled_scope at all.
--
-- FIX: thread the already-computed NEW.metadata->>'cancelled_scope' into that one shared jsonb
-- payload (used by every status branch -- harmless/absent for every non-cancelled status, and for
-- the 'individual_request' / generic cancellation flavors, which are unaffected: this migration
-- does not change whether THEY show Chat). NotificationDetailScreen (Flutter, companion change)
-- then hides "Open Chat" specifically when cancelled_scope = 'travel_plan', and only then -- no
-- other notification type or cancellation flavor is touched. This is a precise fix scoped to
-- exactly the reported event, not a global "remove Open Chat" change.
--
-- No title/body wording changes, no notification routing changes, no new notification type, no
-- change to who gets notified or when. Only one new key added to an existing jsonb payload.
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

                IF NEW.route_id IS NOT NULL THEN
                    SELECT pickup_city, destination_city INTO v_plan_pickup, v_plan_dest
                    FROM public.rider_travel_plans WHERE id = NEW.route_id;
                END IF;

                IF NEW.cancelled_by_actor = 'user' THEN
                    v_title := 'Booking Cancelled';
                    v_body := 'You cancelled this request.';

                ELSIF NEW.metadata->>'cancelled_scope' = 'travel_plan' THEN
                    v_title := 'Travel Plan Cancelled';
                    IF v_plan_pickup IS NOT NULL AND v_plan_dest IS NOT NULL THEN
                        v_body := 'Your traveller has cancelled the travel plan from ' || v_plan_pickup || ' to ' || v_plan_dest
                            || ' due to ' || COALESCE(NULLIF(btrim(NEW.cancelled_reason), ''), 'unavoidable reasons')
                            || '. Please search for another available traveller.';
                    ELSE
                        v_body := 'Your traveller has cancelled the travel plan due to '
                            || COALESCE(NULLIF(btrim(NEW.cancelled_reason), ''), 'unavoidable reasons')
                            || '. Please search for another available traveller.';
                    END IF;

                ELSIF NEW.metadata->>'cancelled_scope' = 'individual_request' THEN
                    v_title := 'Booking Cancelled';
                    IF v_plan_pickup IS NOT NULL AND v_plan_dest IS NOT NULL THEN
                        v_body := 'Your request for the travel plan from ' || v_plan_pickup || ' to ' || v_plan_dest
                            || ' was cancelled by the traveller. You can search for another available traveller.';
                    ELSE
                        v_body := 'Your request was cancelled by the traveller. You can search for another available traveller.';
                    END IF;

                ELSE
                    v_title := 'Booking Cancelled';
                    v_body := 'Your traveller cancelled this trip. Please choose another available partner.';
                END IF;
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
                'status', NEW.status,
                -- Issue 5 (Phase 2): the ONE new field. NULL/absent for every non-cancelled status
                -- and for the 'individual_request'/generic cancellation flavors -- the client only
                -- ever acts on it when it is literally 'travel_plan'.
                'cancelled_scope', NEW.metadata->>'cancelled_scope'
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
