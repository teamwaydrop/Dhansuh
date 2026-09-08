-- Migration: Give the passenger a proper, specific push-notification message when their order is
-- auto-expired, instead of on_order_status_update()'s generic fallback string.
-- Date: 2026-08-06 (rebased during reconciliation; originally authored 2026-08-02)
--
-- 20260806000004_add_expire_stale_searching_orders_and_schedule.sql starts writing
-- order_status = 'expired' for the first time anywhere in this codebase. on_order_status_update()
-- (AFTER UPDATE OF order_status ON public.orders FOR EACH ROW) already fires automatically on this
-- transition and would otherwise fall through to its ELSE branch: "Order Status Update" / "There is
-- a new update on your order. Status is now: expired" -- functional, not a bug, but not the clear
-- "no drivers were available" message a passenger actually needs here.
--
-- REBASE NOTE (reconciliation, 2026-08-04): this migration was originally written against the
-- 20260730000001 definition of on_order_status_update(). Before it could be deployed,
-- 20260806000000_fix_intercity_parcel_start_trip_notification_wording.sql was applied directly to
-- production and redefined the SAME function, adding (a) an intercity 'accepted' dedup guard
-- (v_has_linked_request check before the "Partner Started the Trip" send) and (b) corrected wording
-- for the picked_up/ongoing intercity_parcel branch ("Trip Started 🚚" instead of "Parcel Picked Up",
-- since Start Trip is a plan-level action, not a physical pickup event). This migration is rebased
-- to layer its one new 'expired' ELSIF branch on top of THAT current body -- both (a) and (b) are
-- preserved verbatim below, not reverted. Every other branch is unchanged from 20260806000000.
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
                SELECT EXISTS (
                    SELECT 1 FROM public.intercity_requests
                    WHERE parcel_id = NEW.id
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
        ELSIF NEW.order_status = 'expired' THEN
            -- New branch (this migration): the only addition relative to 20260806000000.
            v_title := 'No Drop Partners Available ⏱️';
            v_body := 'We couldn''t find a Drop Partner for your request in time. Please try booking again.';
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
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;
