-- Migration: Issue 4 -- when a passenger/user cancels an intercity booking, the Traveller's push
-- notification already correctly says "The passenger cancelled the trip." (not misattributed to the
-- traveller -- that correction shipped in 20260822000000/20260901000024/20260901000025, which this
-- migration does not touch), but it never included WHY -- the actual, already-stored cancellation
-- reason (orders.cancel_reason, set from the passenger's own cancellation flow, e.g.
-- intercity_tracking_screen.dart) was collected and persisted but never surfaced to the traveller.
--
-- ROOT CAUSE: send_order_status_notifications_core()'s rider-cancellation-notify block (Part of the
-- p_cancelled_by-accepting overload) never received the reason at all -- neither
-- on_order_status_update() (the trigger that invokes it via pg_net) nor the RPC's own parameter
-- list carried orders.cancel_reason through the chain, even though it was already written to the
-- database in the SAME row this trigger fires from (NEW.cancel_reason).
--
-- FIX: thread the already-stored reason through unchanged -- on_order_status_update() now also
-- passes NEW.cancel_reason as p_cancel_reason, and send_order_status_notifications_core() gains
-- that one new (default-NULL) parameter, used ONLY to enrich the existing
-- "v_is_intercity AND p_cancelled_by = 'user'" traveller-notification body with the real reason.
-- Falls back to "not specified" (never a literal "null"/empty string) when the reason is null or
-- blank -- e.g. an older order row, or a cancellation path that genuinely has none. No other branch,
-- title, or condition changes:
--   - The p_cancelled_by = 'rider' self-notification skip (traveller cancelling their own trip)
--     is untouched -- that case still sends nothing here, and the existing traveller-cancel wording
--     the PASSENGER receives (owned entirely by on_intercity_request_change(), a separate function
--     this migration does not touch) is unaffected.
--   - The non-intercity ELSE branch ("The order you accepted has been cancelled by the customer.")
--     is reproduced byte-for-byte -- local ride/parcel cancellation notifications are unchanged.
--   - cancelled_by_actor='user' (intercity_requests) and p_cancelled_by='user' (orders) semantics
--     from 20260901000024/20260901000025 are preserved exactly; this migration only adds a reason
--     string to an existing message, it does not change who gets notified or which branch fires.
--   - No duplicate notification is introduced: this is the exact same single PERFORM
--     send_push_notification_fnc() call site as before, just with a longer body string.

-- =====================================================================================
-- 1. Drop the old 10-parameter overload before creating the 11-parameter replacement --
--    Postgres treats a different parameter count as a distinct function, and leaving both defined
--    would make PostgREST's RPC dispatch ambiguous for the one real caller (on_order_status_update,
--    updated below to always pass all 11).
-- =====================================================================================
DROP FUNCTION IF EXISTS public.send_order_status_notifications_core(
    uuid, text, text, text, integer, text, text, uuid, uuid, text
);

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
                        v_title := 'Trip Started 🚚';
                        v_body := E'Your traveller has started the trip with your parcel.\n\nTrack it live in the WayDrop app.';
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
            -- Preserved byte-for-byte: passenger-facing intercity cancellation copy is fully owned
            -- by on_intercity_request_change() -- sending it again here would duplicate it.
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

        -- Send to passenger (unchanged)
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

        -- 2. Notify Rider if order was cancelled -- unchanged skip condition (traveller cancelling
        -- their own trip never self-notifies here). THIS MIGRATION: the intercity/user-cancelled
        -- branch now names the actual, already-stored cancellation reason instead of only naming
        -- the actor. COALESCE/NULLIF/btrim mirrors the exact null/blank-safe pattern already used
        -- elsewhere in this codebase (e.g. on_intercity_request_change()'s travel-plan-cancelled
        -- copy) -- never renders a literal "null" or an empty "Reason: ." string.
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

        -- 3. Notify Rider on completion too, for intercity trips (unchanged).
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

-- =====================================================================================
-- 2. on_order_status_update() -- one new key in the pg_net JSON body, threading the already-stored
--    NEW.cancel_reason through to the RPC above. Every other field/condition unchanged.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        BEGIN
            SELECT decrypted_secret INTO v_service_role_key
            FROM vault.decrypted_secrets
            WHERE name = 'supabase_service_role_key'
            LIMIT 1;

            IF v_service_role_key IS NOT NULL THEN
                PERFORM net.http_post(
                    url := v_supabase_url || '/rest/v1/rpc/send_order_status_notifications_core',
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'Authorization', 'Bearer ' || v_service_role_key,
                        'apikey', v_service_role_key
                    ),
                    body := jsonb_build_object(
                        'p_order_id', NEW.id,
                        'p_old_status', OLD.order_status,
                        'p_new_status', NEW.order_status,
                        'p_order_type', NEW.order_type,
                        'p_estimated_duration_min', NEW.estimated_duration_min,
                        'p_pickup_otp', NEW.pickup_otp,
                        'p_delivery_otp', NEW.delivery_otp,
                        'p_user_id', NEW.user_id,
                        'p_rider_id', NEW.rider_id,
                        'p_cancelled_by', NEW.cancelled_by,
                        'p_cancel_reason', NEW.cancel_reason
                    ),
                    timeout_milliseconds := 5000
                );
            ELSE
                RAISE WARNING 'on_order_status_update: vault secret "supabase_service_role_key" is not configured -- skipping async notification enqueue for order %', NEW.id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'on_order_status_update: failed to enqueue async notification for order %: %', NEW.id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$function$;
