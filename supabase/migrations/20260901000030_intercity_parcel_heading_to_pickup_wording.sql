-- Migration: Issue 6 (Phase 2) -- misleading "Trip Started" wording for an intercity PARCEL
-- booking. When the traveller starts the trip (intercity_requests.status -> 'in_progress'), the
-- user received: "Your traveller has started the trip with your parcel." This implies the parcel
-- is already collected/in transit, but at this point the traveller has only started travelling
-- TOWARD the pickup location -- the parcel has not been picked up yet.
--
-- TRACE (two call sites produce this exact string, both confirmed live in this schema):
--   1. on_intercity_request_change() -- the PRIMARY path: fires on every intercity_requests UPDATE
--      whose status changes to 'in_progress' (set by start_intercity_trip_for_plan() when the
--      traveller taps "Start Trip"). This is what actually reaches the passenger for any order
--      with a linked, confirmed/paid/in_progress/completed intercity_requests row -- true for
--      every normal Travel Together booking.
--   2. send_order_status_notifications_core() -- a FALLBACK only: its own
--      "IF NOT v_has_linked_request THEN" guard means this copy fires only for an intercity parcel
--      order that reaches picked_up/ongoing with NO linked intercity_requests row at all (an edge
--      case outside the normal Travel Together flow). Kept consistent with (1) so the wording never
--      disagrees depending on which path happens to fire.
--
-- FIX: both sites now say "Your traveller has started the trip and is heading towards you to pick
-- up the parcel." -- title changed from "Trip Started 🚚" to "Traveller Heading to Pickup 🚚" so
-- the heading itself is unambiguous too. SCOPE, precisely limited to this one branch:
--   - The intercity RIDE ('booking_type'/order_type != parcel) sibling wording in both functions is
--     untouched -- the passenger themselves is being picked up, so "Trip Started" was never
--     ambiguous there.
--   - The parcel PICKUP notification ('rider_arrived'/'Partner Arrived'), the in-transit/ongoing
--     tracking screen, and the 'completed'/'Parcel Delivered' wording are all untouched -- only the
--     'in_progress' transition's copy changes.
--   - Local parcel wording (order_type='local_parcel') is untouched -- this is the intercity-only
--     branch in both functions.

-- =====================================================================================
-- 1. on_intercity_request_change() -- only the 'in_progress' + booking_type='parcel' branch
--    changes. Every other branch, including the ride sibling right next to it, is reproduced
--    byte-for-byte from 20260901000029 (which itself only added the Issue 5 cancelled_scope field).
-- =====================================================================================
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
                -- THIS MIGRATION (Issue 6): the parcel has NOT been picked up yet -- the traveller
                -- has only just started travelling TOWARD the pickup location.
                v_title := 'Traveller Heading to Pickup 🚚';
                v_body := E'Your traveller has started the trip and is heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app.';
            ELSE
                -- Unchanged: intercity RIDE passenger wording.
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

-- =====================================================================================
-- 2. send_order_status_notifications_core() -- fallback path only (fires when an intercity_parcel
--    order has NO linked intercity_requests row reaching confirmed/paid/in_progress/completed).
--    Only the intercity+parcel branch of the picked_up/ongoing status changes; the intercity+ride
--    sibling, and every other branch (accepted, rider_arrived, rider_at_drop, completed/delivered,
--    cancelled, expired, the local_parcel/ride/generic branches, and both rider-facing
--    notifications), are reproduced byte-for-byte from 20260901000028.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core(
    p_order_id uuid,
    p_old_status text,
    p_new_status text,
    p_order_type text,
    p_estimated_duration_min integer,
    p_pickup_otp text,
    p_delivery_otp text,
    p_user_id uuid,
    p_rider_id uuid,
    p_cancelled_by text DEFAULT NULL::text,
    p_cancel_reason text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
    v_otp text := '';
    v_is_intercity boolean := false;
    v_is_intercity_parcel boolean := false;
    v_is_local_parcel boolean := false;
    v_eta_text text := '';
    v_has_linked_request boolean := false;
BEGIN
    IF p_old_status IS DISTINCT FROM p_new_status THEN
        v_is_intercity := COALESCE(p_order_type LIKE 'intercity%', false);
        v_is_intercity_parcel := COALESCE(p_order_type = 'intercity_parcel', false);
        v_is_local_parcel := COALESCE(p_order_type = 'local_parcel', false);

        IF p_new_status = 'accepted' THEN
            IF v_is_intercity THEN
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = p_order_id
                      AND status IN ('confirmed', 'paid', 'in_progress', 'completed')
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF p_estimated_duration_min IS NOT NULL THEN
                        v_eta_text := to_char(now() + (p_estimated_duration_min || ' minutes')::interval, 'HH12:MI AM');
                    ELSE
                        v_eta_text := 'shortly';
                    END IF;
                    v_title := 'Your Partner Started the Trip';
                    v_body := 'Your travel partner has started the journey. Please get ready. Estimated arrival: ' || v_eta_text;
                END IF;
            ELSIF p_order_type = 'ride' THEN
                v_title := 'Ride Accepted 🚗';
                v_body := 'Your ride has been accepted. Your partner is on the way.';
            ELSIF v_is_local_parcel THEN
                v_title := 'Order Accepted 📦';
                v_body := 'A Drop Partner has accepted your order and is on the way!';
            ELSE
                v_title := 'Order Accepted 🚗';
                v_body := 'A rider has accepted your order and is on the way!';
            END IF;
        ELSIF p_new_status = 'rider_arrived' THEN
            v_otp := COALESCE(p_pickup_otp, '');
            IF v_is_intercity THEN
                v_title := 'Partner Arrived';
                v_body := 'Your travel partner has arrived at the pickup point. Please meet them. Share OTP ' || v_otp || ' to begin your trip.';
            ELSIF p_order_type = 'ride' THEN
                v_title := 'Your Partner has Arrived! 👋';
                v_body := 'Your partner has arrived. Share OTP ' || v_otp || ' with your partner to start your trip.';
            ELSIF v_is_local_parcel THEN
                v_title := 'Drop Partner at Pickup Location 📦';
                v_body := 'Your Drop Partner has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';
            ELSE
                v_title := 'Rider at Pickup Location 📦';
                v_body := 'Your rider has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';
            END IF;
        ELSIF p_new_status = 'picked_up' OR p_new_status = 'ongoing' THEN
            IF v_is_intercity THEN
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = p_order_id
                      AND status IN ('confirmed', 'paid', 'in_progress', 'completed')
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF v_is_intercity_parcel THEN
                        -- THIS MIGRATION (Issue 6): kept consistent with
                        -- on_intercity_request_change()'s 'in_progress' branch above -- the parcel
                        -- has not been picked up yet at this point.
                        v_title := 'Traveller Heading to Pickup 🚚';
                        v_body := E'Your traveller has started the trip and is heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app.';
                    ELSE
                        v_title := 'Trip Started 🚗';
                        v_body := E'Your traveller has started the trip.\n\nTrack the live journey in the WayDrop app.';
                    END IF;
                END IF;
            ELSIF v_is_local_parcel THEN
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your Drop Partner''s live location on the map.';
            ELSE
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your rider''s live location on the map.';
            END IF;
        ELSIF p_new_status = 'rider_at_drop' THEN
            v_otp := COALESCE(p_delivery_otp, '');
            IF v_is_local_parcel THEN
                v_title := 'Drop Partner Reached Drop-off 📍';
                v_body := 'Your Drop Partner has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
            ELSE
                v_title := 'Rider Reached Drop-off 📍';
                v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
            END IF;
        ELSIF p_new_status = 'completed' OR p_new_status = 'delivered' THEN
            IF v_is_intercity THEN
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = p_order_id
                      AND status = 'completed'
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF v_is_intercity_parcel THEN
                        v_title := 'Parcel Delivered 🎉';
                        v_body := E'Your parcel has been delivered successfully by your Traveller.\n\nThank you for using WayDrop!';
                    ELSE
                        v_title := 'Ride Completed 🎉';
                        v_body := E'Your ride has been completed successfully.\n\nThank you for choosing WayDrop.';
                    END IF;
                END IF;
            ELSIF p_order_type = 'ride' THEN
                v_title := 'Ride Completed 🎉';
                v_body := 'Your ride is completed. Thank you for riding with WayDrop. We hope to see you again!';
            ELSIF v_is_local_parcel THEN
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank your Drop Partner!';
            ELSE
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank the rider!';
            END IF;
        ELSIF p_new_status = 'cancelled' THEN
            IF v_is_intercity THEN
                NULL;
            ELSE
                v_title := 'Order Cancelled ❌';
                v_body := 'Your order has been cancelled.';
            END IF;
        ELSIF p_new_status = 'expired' THEN
            v_title := 'No Drop Partners Available ⏱️';
            v_body := 'We couldn''t find a Drop Partner for your request in time. Please try booking again.';
        ELSE
            v_title := 'Order Status Update ℹ️';
            v_body := 'There is a new update on your order. Status is now: ' || p_new_status;
        END IF;

        IF v_title != '' AND v_body != '' AND p_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                p_user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', p_order_id,
                    'status', p_new_status
                )
            );
        END IF;

        IF p_new_status = 'cancelled' AND p_rider_id IS NOT NULL
           AND NOT (v_is_intercity AND p_cancelled_by = 'rider') THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = p_rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    CASE
                        WHEN v_is_intercity AND p_cancelled_by = 'user' THEN
                            'The passenger cancelled this booking. Reason: '
                            || COALESCE(NULLIF(btrim(p_cancel_reason), ''), 'not specified')
                            || '.'
                        ELSE 'The order you accepted has been cancelled by the customer.'
                    END,
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', p_order_id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;

        IF v_is_intercity AND (p_new_status = 'completed' OR p_new_status = 'delivered') AND p_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = p_rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                IF v_is_intercity_parcel THEN
                    PERFORM public.send_push_notification_fnc(
                        v_rider_user_id,
                        'Delivery Completed 🎉',
                        'Delivery completed successfully! Your earnings have been updated. Thank you for delivering with WayDrop.',
                        jsonb_build_object(
                            'type', 'order_status',
                            'order_id', p_order_id,
                            'status', p_new_status
                        )
                    );
                ELSE
                    PERFORM public.send_push_notification_fnc(
                        v_rider_user_id,
                        'Trip Completed',
                        'Thank you for travelling with Way Drop. Hope to see you again.',
                        jsonb_build_object(
                            'type', 'order_status',
                            'order_id', p_order_id,
                            'status', p_new_status
                        )
                    );
                END IF;
            END IF;
        END IF;
    END IF;
END;
$function$;
