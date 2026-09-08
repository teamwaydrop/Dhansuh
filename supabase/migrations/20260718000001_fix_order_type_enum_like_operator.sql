-- Fixes "operator does not exist: order_type_enum ~~ unknown", thrown on every single
-- order_status update (local ride/parcel included, not just intercity) and on every rider
-- location write.
--
-- Root cause: public.orders.order_type is public.order_type_enum (see
-- 20260603000003_update_order_type_enum.sql), not text. 20260717000009 introduced two LIKE
-- comparisons directly against that enum value (NEW.order_type LIKE '...' / order_type LIKE
-- '...') without casting to text first. Postgres has no ~~ (LIKE) operator defined for enum
-- types, so the expression fails to even evaluate — the whole triggering transaction (e.g. an
-- accept-order UPDATE, or a rider location UPDATE) is rolled back and the error is surfaced to
-- the client as "INVALID_REQUEST operator does not exist: order_type_enum ~~ unknown". This is
-- what broke traveller-accept on intercity requests and order status transitions generally.
--
-- Fix: cast to text before LIKE, in both functions, matching the pattern already used correctly
-- elsewhere in this codebase (e.g. assign_nearby_searching_orders_to_rider casts
-- o.order_type::text at select time).

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
        v_is_intercity := COALESCE(NEW.order_type::text LIKE 'intercity%', false);

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
      AND order_type::text LIKE 'intercity%'
      AND destination_lat IS NOT NULL
      AND destination_lng IS NOT NULL
    LIMIT 1;

    IF v_order.id IS NULL THEN
        RETURN NEW;
    END IF;

    v_dist_km := 6371 * acos(
        LEAST(GREATEST(
            cos(radians(v_order.destination_lat))
            * cos(radians(NEW.current_lat))
            * cos(radians(NEW.current_lng) - radians(v_order.destination_lng))
            + sin(radians(v_order.destination_lat))
            * sin(radians(NEW.current_lat))
        , -1.0), 1.0)
    );

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
