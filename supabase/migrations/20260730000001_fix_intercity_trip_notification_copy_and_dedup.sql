-- Migration: Fix intercity Start Trip / Complete Trip push notification copy and eliminate a
-- duplicate-notification bug on trip completion.
-- Date: 2026-07-30
--
-- BUG #1 (wording): on_intercity_request_change() (last touched by 20260729000003) sends the
-- SAME generic, type-mixing copy to every passenger regardless of whether they booked an
-- intercity RIDE or an intercity PARCEL:
--   'in_progress' (Start Trip):  'Trip on the Way' / 'Traveller has collected the
--       parcel/started the ride. Track live updates!'
--   'completed'   (Complete Trip): 'Trip Completed Successfully' / 'Your shipment/ride has been
--       delivered. Thank the traveller!'
-- Both bodies literally contain "parcel/...ride" or "shipment/ride" -- every passenger sees both
-- words no matter which they booked. Fixed by branching on NEW.booking_type ('ride' | 'parcel'),
-- the same column this function already uses correctly in its own INSERT branch (New Travel
-- Match vs New Parcel Match), to the exact spec copy for each of the four cases.
--
-- BUG #2 (duplicate notification): update-order-status/index.ts's "SYNC THE LINKED
-- intercity_requests..." block writes intercity_requests.status='completed' in the same request
-- that flips orders.order_status to 'completed'/'delivered'. That means BOTH
-- on_order_status_update() (fires on orders.order_status) AND on_intercity_request_change()
-- (fires on intercity_requests.status) send the passenger a completion push for the exact same
-- event -- two notifications, with two different (and both previously wrong) texts. Verified
-- this is not a rare edge case: every intercity order that ever reaches 'picked_up'/'ongoing' or
-- 'completed'/'delivered' has necessarily gone through start_intercity_trip() or
-- start_intercity_trip_for_plan() first (order_status only leaves 'accepted' via those RPCs or
-- via update-order-status after Start Trip), and both RPCs require a live intercity_requests row
-- for that exact order+traveller pair to do anything at all -- so a linked row always exists by
-- the time these transitions fire push notifications. Fixed by having
-- on_order_status_update()'s intercity passenger-facing picked_up/ongoing and
-- completed/delivered branches check for that linked row and skip sending (deferring entirely to
-- on_intercity_request_change(), which is the only place with access to booking_type and can
-- therefore send the correctly-worded copy) -- but only when a linked row is actually found, so
-- an intercity order that somehow has none (not verified to be reachable, but not proven
-- impossible either) still gets a notification instead of silently losing one.
--
-- Every other branch of on_intercity_request_change() (INSERT copy, discussion_started,
-- confirmed, rejected, paid, cancelled, the reject-fallback block, the rider's own 'confirmed'
-- copy) is preserved byte-for-byte from 20260729000003. Every other branch of
-- on_order_status_update() (local ride/parcel wording, accepted/rider_arrived/rider_at_drop,
-- cancelled) is preserved byte-for-byte from 20260718000001.

-- =====================================================================
-- 1. on_intercity_request_change(): type-aware Start Trip / Complete Trip copy.
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
            -- Root-cause fix (this migration): traveller pressed Start Trip. Branch strictly on
            -- booking_type -- never mix "parcel"/"ride" wording into the same message.
            v_notify_user_id := v_passenger_user_id;
            IF NEW.booking_type = 'parcel' THEN
                v_title := 'Parcel Picked Up 📦';
                v_body := E'Your parcel has been collected by the traveller.\n\nTrack your parcel live in the WayDrop app.';
            ELSE
                v_title := 'Trip Started 🚗';
                v_body := E'Your traveller has started the trip.\n\nTrack the live journey in the WayDrop app.';
            END IF;

        ELSIF NEW.status = 'completed' THEN
            -- Root-cause fix (this migration): traveller pressed Complete Trip. Same
            -- booking_type branch as above -- never mention "parcel" to a ride passenger or
            -- "delivery"/"shipment" to a parcel customer's ride-flavored counterpart.
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

-- =====================================================================
-- 2. on_order_status_update(): (a) fix the intercity passenger-facing picked_up/ongoing and
--    completed/delivered copy to also branch parcel vs ride (defense in depth -- see below for
--    why it should rarely if ever actually send), (b) skip sending that passenger notification
--    entirely when a linked intercity_requests row exists, since on_intercity_request_change()
--    already sent the (correctly-worded, per fix #1) equivalent for that same event -- this is
--    what eliminates the duplicate push described above, (c) branch the rider-facing completion
--    copy the same way for consistency. Local ride/parcel branches, OTP/arrival copy, and
--    cancellation copy are preserved byte-for-byte from 20260718000001.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
    v_otp text := '';
    v_is_intercity boolean := false;
    v_is_intercity_parcel boolean := false;
    v_eta_text text := '';
    v_has_linked_request boolean := false;
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        v_is_intercity := COALESCE(NEW.order_type::text LIKE 'intercity%', false);
        v_is_intercity_parcel := COALESCE(NEW.order_type::text = 'intercity_parcel', false);

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
                -- Bug fix (this migration): only send this fallback if on_intercity_request_change
                -- has NOT already sent the correctly-worded Start Trip push for this same order
                -- (i.e. no linked, live intercity_requests row -- should not normally happen, see
                -- migration header, but never silently drop the notification if it somehow does).
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = NEW.id
                      AND status IN ('confirmed', 'paid', 'in_progress', 'completed')
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF v_is_intercity_parcel THEN
                        v_title := 'Parcel Picked Up 📦';
                        v_body := E'Your parcel has been collected by the traveller.\n\nTrack your parcel live in the WayDrop app.';
                    ELSE
                        v_title := 'Trip Started 🚗';
                        v_body := E'Your traveller has started the trip.\n\nTrack the live journey in the WayDrop app.';
                    END IF;
                END IF;
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
                -- Same duplicate-avoidance guard as the picked_up/ongoing branch above.
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = NEW.id
                      AND status = 'completed'
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF v_is_intercity_parcel THEN
                        v_title := 'Parcel Delivered 🎉';
                        v_body := E'Your parcel has been delivered successfully.\n\nThank you for choosing WayDrop.';
                    ELSE
                        v_title := 'Ride Completed 🎉';
                        v_body := E'Your ride has been completed successfully.\n\nThank you for choosing WayDrop.';
                    END IF;
                END IF;
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

        -- Send to passenger (v_title/v_body are both left '' by the dedup guards above when the
        -- other trigger already handled this event -- the existing "both non-empty" check below
        -- already skips sending in that case, no new condition needed here).
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

        -- 3. Notify Rider on completion too, for intercity trips (Part 21: "notify both").
        -- Branched by parcel vs ride for consistency with the passenger-facing copy above.
        IF v_is_intercity AND (NEW.order_status = 'completed' OR NEW.order_status = 'delivered') AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                IF v_is_intercity_parcel THEN
                    PERFORM public.send_push_notification_fnc(
                        v_rider_user_id,
                        'Parcel Delivered 🎉',
                        'Thank you for delivering with Way Drop. Hope to see you again.',
                        jsonb_build_object(
                            'type', 'order_status',
                            'order_id', NEW.id,
                            'status', NEW.order_status
                        )
                    );
                ELSE
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
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
