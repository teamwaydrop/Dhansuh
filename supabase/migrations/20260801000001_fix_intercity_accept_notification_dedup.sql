-- =====================================================================
-- P2 FIX: on_order_status_update()'s intercity "accepted" branch still sends a wrong,
-- duplicate push notification at accept time.
-- =====================================================================
-- ROOT CAUSE: accept_intercity_request() (20260728000000) does three things in one
-- transaction: (1) sets intercity_requests.status='confirmed' (fires
-- on_intercity_request_change()'s 'confirmed' branch -> correct "Travel Request Accepted"
-- push), (2) sets orders.order_status='accepted' (fires on_order_status_update()'s
-- 'accepted' branch), (3) inserts a system chat message (fires on_new_chat_message -> a
-- third push). 20260730000001_fix_intercity_trip_notification_copy_and_dedup.sql already
-- fixed this exact duplicate/wrong-copy pattern for the picked_up/ongoing and
-- completed/delivered branches (skip sending from on_order_status_update() when a linked
-- intercity_requests row shows the other trigger already handled it), but explicitly left
-- the 'accepted' branch untouched -- it still unconditionally sends "Your Partner Started
-- the Trip" / "...has started the journey..." at ACCEPT time, before the trip has started
-- (order_status stays 'accepted' throughout the wait, per
-- 20260720000000_traveller_available_and_trip_lifecycle.sql's own comment) -- factually
-- wrong, and redundant with on_intercity_request_change()'s correct push for the same event.
--
-- FIX: apply the exact same dedup pattern already established in this function (see the
-- picked_up/ongoing and completed/delivered branches directly below) to the 'accepted'
-- branch: for intercity orders, skip sending from here when a linked intercity_requests row
-- is already in 'confirmed' or later, deferring entirely to
-- on_intercity_request_change()'s "Travel Request Accepted" push. Every other branch is
-- preserved byte-for-byte from 20260730000001.
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
                -- P2 fix (this migration): only send this fallback if
                -- on_intercity_request_change has NOT already sent "Travel Request Accepted"
                -- for this same event (i.e. no linked intercity_requests row already at
                -- confirmed-or-later) -- mirrors the picked_up/ongoing and completed/delivered
                -- guards below. Never silently drop the notification if no linked row exists.
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = NEW.id
                      AND status IN ('confirmed', 'paid', 'in_progress', 'completed')
                ) INTO v_has_linked_request;

                IF NOT v_has_linked_request THEN
                    IF NEW.estimated_duration_min IS NOT NULL THEN
                        v_eta_text := to_char(now() + (NEW.estimated_duration_min || ' minutes')::interval, 'HH12:MI AM');
                    ELSE
                        v_eta_text := 'shortly';
                    END IF;
                    v_title := 'Your Partner Started the Trip';
                    v_body := 'Your travel partner has started the journey. Please get ready. Estimated arrival: ' || v_eta_text;
                END IF;
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
                -- Bug fix (20260730000001): only send this fallback if on_intercity_request_change
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
