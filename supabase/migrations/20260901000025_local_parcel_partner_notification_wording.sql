-- Migration: local_parcel push-notification copy says "Drop Partner", never "Rider".
--
-- RECONCILED AGAINST ACTUAL PRODUCTION (2026-08-23, read-only verification): the version of this
-- migration originally drafted for this fix was built on top of the last LOCAL migration file
-- touching send_order_status_notifications_core() (20260822000000) -- but a read-only audit
-- (pg_get_functiondef against the linked production project) found that production's actual live
-- function body is NOT that version. It contains two further fixes that were applied directly to
-- production and never captured as a local migration file:
--   1. The 'cancelled' branch no longer sends ANY passenger-facing copy for intercity orders
--      (`IF v_is_intercity THEN NULL; ELSE ... END IF;`) -- that copy is "fully owned by
--      on_intercity_request_change" (per the production comment); sending it again here
--      duplicated the passenger's cancellation notification on every intercity cancellation.
--   2. The rider-notify block's actor check compares `p_cancelled_by = 'user'`, not `'passenger'`
--      -- orders.cancelled_by is the real Postgres enum `cancelled_by_enum`
--      ('user' | 'rider' | 'admin' | 'system'); there is no 'passenger' label, so a comparison
--      against 'passenger' could never match anything.
-- This migration is a full rewrite, reproducing that VERIFIED CURRENT PRODUCTION function
-- byte-for-byte (confirmed via pg_get_functiondef(30799::oid) against the linked project, saved
-- to a local reference file before writing this migration -- see
-- test/phase1_local_parcel_partner_notification_wording_regression_test.dart for the assertions
-- that pin every byte-for-byte-preserved branch), and adds ONLY the local_parcel Partner-wording
-- branches below. Neither of the two production-only fixes above is touched, weakened, or
-- reordered by this migration.
--
-- ROOT CAUSE (the actual fix this migration makes): send_order_status_notifications_core() is the
-- single source of every order_status push notification's title/body -- both the foreground alert
-- (shown while the app is open) and the background/killed-app system-tray notification (FCM)
-- render exactly this same server-generated title/body. Several of its branches use generic
-- "rider" wording in their ELSE fallback (order_type not 'ride', not intercity) that ALSO fires
-- for local_parcel: "A rider has accepted your order...", "Rider at Pickup Location", "Track your
-- rider's live location...", "Rider Reached Drop-off" (this last one wasn't even branched by
-- order_type at all -- it fired for every order type reaching 'rider_at_drop'), and "...thank the
-- rider!". The client side (lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart)
-- already correctly uses "Drop Partner"/"delivery partner" throughout its own in-app banners --
-- this migration brings the server-generated push copy in line with that existing, already-
-- established app terminology (see e.g. the pre-existing "No Drop Partners Available" wording a
-- few lines below, unchanged by this migration).
--
-- SCOPE: every change below is gated to `p_order_type = 'local_parcel'` specifically.
--   - 'ride' wording (Ride Accepted / Your Partner has Arrived / etc.) is untouched.
--   - Every intercity branch (v_is_intercity) is untouched, including both production-only fixes
--     above.
--   - Any OTHER non-ride/non-intercity/non-local_parcel order_type still reaching these ELSE
--     branches (food_delivery/grocery_delivery/batch_delivery/ride_sharing) keeps the exact
--     original generic "rider" wording, unchanged -- this migration only carves local_parcel out
--     of that shared bucket, it does not touch what remains in it.
--   - 'expired'/notification routing/payload shape/grants are byte-for-byte unchanged.
--   - No pricing, GST, commission, tax, payment, dispatch, or subscription logic is anywhere in
--     this function; none of it is touched by this migration.

CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core(p_order_id uuid, p_old_status text, p_new_status text, p_order_type text, p_estimated_duration_min integer, p_pickup_otp text, p_delivery_otp text, p_user_id uuid, p_rider_id uuid, p_cancelled_by text DEFAULT NULL::text)
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
    -- THIS MIGRATION: the one new local variable, added purely to gate the local_parcel wording
    -- branches below -- mirrors v_is_intercity_parcel's exact derivation shape.
    v_is_local_parcel boolean := false;
    v_eta_text text := '';
    v_has_linked_request boolean := false;
BEGIN
    IF p_old_status IS DISTINCT FROM p_new_status THEN
        v_is_intercity := COALESCE(p_order_type LIKE 'intercity%', false);
        v_is_intercity_parcel := COALESCE(p_order_type = 'intercity_parcel', false);
        -- THIS MIGRATION.
        v_is_local_parcel := COALESCE(p_order_type = 'local_parcel', false);

        -- 1. Notify Passenger (p_user_id) for status updates
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
                -- THIS MIGRATION.
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
                -- THIS MIGRATION.
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
                        v_title := 'Trip Started 🚚';
                        v_body := E'Your traveller has started the trip with your parcel.\n\nTrack it live in the WayDrop app.';
                    ELSE
                        v_title := 'Trip Started 🚗';
                        v_body := E'Your traveller has started the trip.\n\nTrack the live journey in the WayDrop app.';
                    END IF;
                END IF;
            ELSIF v_is_local_parcel THEN
                -- THIS MIGRATION.
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your Drop Partner''s live location on the map.';
            ELSE
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your rider''s live location on the map.';
            END IF;
        ELSIF p_new_status = 'rider_at_drop' THEN
            v_otp := COALESCE(p_delivery_otp, '');
            -- THIS MIGRATION: this branch was not gated by order_type at all in production -- it
            -- fired the "Rider Reached Drop-off" wording unconditionally for every order type
            -- reaching 'rider_at_drop'. Now branched: local_parcel gets Drop Partner wording,
            -- every other order type (including intercity_parcel and 'ride', if either ever
            -- reaches this status) keeps the exact original wording, unchanged.
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
                -- THIS MIGRATION.
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank your Drop Partner!';
            ELSE
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank the rider!';
            END IF;
        ELSIF p_new_status = 'cancelled' THEN
            -- PRODUCTION-ONLY FIX (preserved byte-for-byte, NOT part of this migration's change):
            -- passenger-facing intercity cancellation copy is fully owned by
            -- on_intercity_request_change -- sending it again here duplicated it on every
            -- intercity cancellation path. Leave title/body empty so the passenger-notify block
            -- below is a no-op for intercity; non-intercity wording is unchanged.
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

        -- Send to passenger (v_title/v_body are both left '' by the dedup guards above when the
        -- other trigger already handled this event -- the existing "both non-empty" check below
        -- already skips sending in that case, no new condition needed here).
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

        -- 2. Notify Rider if order was cancelled -- Issue 7 fix: skip this self-notification when
        -- the rider/traveller is the one who cancelled their own intercity order (they already
        -- know); every other case (non-intercity, or passenger-cancelled) is unchanged, with the
        -- intercity passenger-cancelled wording corrected to name the actual actor.
        IF p_new_status = 'cancelled' AND p_rider_id IS NOT NULL
           AND NOT (v_is_intercity AND p_cancelled_by = 'rider') THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = p_rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    CASE
                        -- PRODUCTION-ONLY FIX (preserved byte-for-byte, NOT part of this
                        -- migration's change): orders.cancelled_by is cancelled_by_enum ('user' |
                        -- 'rider' | 'admin' | 'system') -- there is no 'passenger' label, so this
                        -- comparison could never match. Corrected to 'user', the actual value
                        -- written for a passenger/customer-initiated cancellation. This migration
                        -- introduces NO 'passenger' sentinel anywhere.
                        WHEN v_is_intercity AND p_cancelled_by = 'user' THEN 'The passenger cancelled the trip.'
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

        -- 3. Notify Rider on completion too, for intercity trips (Part 21: "notify both").
        -- Branched by parcel vs ride for consistency with the passenger-facing copy above.
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

GRANT EXECUTE ON FUNCTION public.send_order_status_notifications_core(
    uuid, text, text, text, integer, text, text, uuid, uuid, text
) TO service_role;
