-- Migration: move order-status push-notification composition/dispatch off the synchronous
-- orders.order_status UPDATE transaction.
--
-- ROOT CAUSE (live Ride 1->2->3->4 instrumentation, 2026-08-08, proven via diagnostic_timings):
-- update-order-status's `orders` UPDATE progressively degraded across one real session (Ride 1:
-- 214-485ms: Ride 2: up to 5.5s; Ride 3: 22.8s; Ride 4: two PROVABLY OVERLAPPING pairs of
-- concurrent requests for the same order, individual UPDATEs waiting up to 46.5s for the row
-- lock). trigger_order_status_update (AFTER UPDATE OF order_status, unconditional -- fires on
-- EVERY status transition) calls send_push_notification_fnc() up to 3 times per invocation
-- (passenger notify, rider-cancelled notify, rider-completed notify for intercity), each of which
-- INSERTs into public.notifications, which itself fires trigger_notification_insert ->
-- deliver_push_notification_http_fnc() -> a vault.decrypted_secrets lookup (pgsodium decrypt, not
-- free) + net.http_post. All of that runs synchronously, sequentially, inside the SAME transaction
-- as the orders UPDATE -- extending exactly how long that transaction (and therefore the row lock
-- every concurrent/retried request queues behind) stays open.
--
-- FIX: same already-proven-safe pattern as assign_nearby_searching_orders_on_rider_freed()
-- (20260809000001_async_rider_freed_rematch.sql) -- the trigger function itself now does exactly
-- ONE net.http_post enqueue (a fast queue insert, not a synchronous notification-delivery chain)
-- instead of running the notification logic inline. The ACTUAL notification composition/dispatch
-- logic is unchanged byte-for-byte -- moved verbatim into send_order_status_notifications_core(),
-- called a moment after this transaction commits via the same PostgREST RPC + vault-secret pattern
-- already live in production. Same messages, same recipients, same conditions, same result -- the
-- only change is that it no longer runs inside, or adds its cost to, the orders UPDATE itself.
-- Best-effort: if the async enqueue itself fails, it's logged (RAISE WARNING), never thrown -- this
-- trigger never affected the order transition's own outcome before, and still doesn't.

-- =====================================================================================
-- 1. Notification composition/dispatch logic, extracted verbatim from the old
--    on_order_status_update() trigger body, parameterized instead of reading NEW.*/OLD.*.
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
    p_rider_id uuid
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
    v_eta_text text := '';
    v_has_linked_request boolean := false;
BEGIN
    -- Defense-in-depth: the caller (on_order_status_update()) already only enqueues this when
    -- old/new genuinely differ, but re-check here too in case this is ever invoked directly.
    IF p_old_status IS DISTINCT FROM p_new_status THEN
        v_is_intercity := COALESCE(p_order_type LIKE 'intercity%', false);
        v_is_intercity_parcel := COALESCE(p_order_type = 'intercity_parcel', false);

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
                v_title := 'Your Rider has Arrived! 👋';
                v_body := 'Your rider has arrived. Share OTP ' || v_otp || ' with the rider to start your trip.';
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
            ELSE
                v_title := 'Trip on the Way 🗺️';
                v_body := 'Your trip has started. Track your rider''s live location on the map.';
            END IF;
        ELSIF p_new_status = 'rider_at_drop' THEN
            v_otp := COALESCE(p_delivery_otp, '');
            v_title := 'Rider Reached Drop-off 📍';
            v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
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
        ELSIF p_new_status = 'cancelled' THEN
            v_title := 'Order Cancelled ❌';
            v_body := 'Your order has been cancelled.';
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

        -- 2. Notify Rider if order was cancelled
        IF p_new_status = 'cancelled' AND p_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = p_rider_id;

            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    'The order you accepted has been cancelled by the customer.',
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
                        'Parcel Delivered 🎉',
                        'Thank you for delivering with Way Drop. Hope to see you again.',
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

-- Postgres grants EXECUTE to PUBLIC by default on CREATE FUNCTION, but this project's default
-- privileges have been found (live, this same investigation) to not always carry that through for
-- the service-role-authenticated PostgREST RPC path -- grant explicitly rather than relying on the
-- default, exactly as assign_nearby_searching_orders_core's own comment already notes was required.
GRANT EXECUTE ON FUNCTION public.send_order_status_notifications_core(
    uuid, text, text, text, integer, text, text, uuid, uuid
) TO service_role;

-- =====================================================================================
-- 2. The trigger function itself: now a thin, fast, best-effort async enqueue -- exactly the
--    same shape as assign_nearby_searching_orders_on_rider_freed() (20260809000001).
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
                        'p_rider_id', NEW.rider_id
                    ),
                    timeout_milliseconds := 5000
                );
            ELSE
                RAISE WARNING 'on_order_status_update: vault secret "supabase_service_role_key" is not configured -- skipping async notification enqueue for order %', NEW.id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Never block the order's own status transition on the async enqueue itself failing --
            -- this trigger only ever sent notifications, it never gated the transition's outcome.
            RAISE WARNING 'on_order_status_update: failed to enqueue async notification for order %: %', NEW.id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$function$;
