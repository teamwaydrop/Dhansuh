-- Migration: actor-aware Intercity cancellation notifications, plus a small Intercity parcel
-- completion-copy polish. Phase 2 (Intercity), Issues 7 and 9-wording.
--
-- ISSUE 7 ROOT CAUSE: cancellation for an accepted intercity order goes through the shared
-- update-order-status edge function, reachable by either the passenger or the assigned rider
-- (both already resolved server-side from the caller's JWT as isPassenger/isDriver). But
-- send_order_status_notifications_core's generic 'cancelled' branch was actor-blind: the
-- passenger was always told a generic "Your order has been cancelled.", and the rider was
-- unconditionally told "The order you accepted has been cancelled by the customer." even when the
-- rider/traveller themselves cancelled it. The client-supplied `changed_by` field could not be
-- used to fix this -- cancel-order/index.ts (the only path both sides cancel an accepted order
-- through) never sends it at all.
--
-- FIX: a new `orders.cancelled_by` column, written by update-order-status (this same PR) in the
-- SAME UPDATE statement that flips order_status to 'cancelled' -- derived exclusively from the
-- server-resolved isDriver/isPassenger, never trusted from the client -- so the AFTER trigger's
-- NEW.* sees it with no race. Threaded through on_order_status_update() as a new, trailing,
-- DEFAULT-valued parameter (backward compatible with every other, not-yet-updated caller), and consumed
-- by send_order_status_notifications_core's 'cancelled' branch, gated to v_is_intercity so LOCAL
-- ride/parcel wording is byte-for-byte unchanged in every case.
--
-- Also updates cascade_cancel_travel_plan_dependents() (Traveller cancels their whole Travel
-- Plan) to tag its own direct orders UPDATE with cancelled_by = 'rider', so its separate generic
-- notification at least agrees with the correct, pre-existing on_intercity_request_change-driven
-- one instead of contradicting it. (That path still sends two separate notifications for one
-- event -- a known, pre-existing duplicate not eliminated by this migration; flagged in the Phase
-- 2 report as a follow-up.)
--
-- ISSUE 9 WORDING: intercity_parcel's 'completed'/'delivered' copy (passenger + rider) is polished
-- to be more specific/actionable. No status/settlement/guard logic changes -- copy only.

-- =====================================================================================
-- 1. orders.cancelled_by -- additive, nullable, forward-only.
-- =====================================================================================
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancelled_by text;

-- =====================================================================================
-- 2. send_order_status_notifications_core: actor-aware 'cancelled' branch (intercity only) +
--    intercity_parcel 'completed' copy polish. Every other branch, and every other order type's
--    'cancelled' wording, is preserved byte-for-byte from 20260821000000.
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
    p_cancelled_by text DEFAULT NULL
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
            ELSIF p_order_type = 'ride' THEN
                v_title := 'Ride Accepted 🚗';
                v_body := 'Your ride has been accepted. Your partner is on the way.';
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
                        v_body := E'Your parcel has been delivered successfully by your Traveller.\n\nThank you for using WayDrop!';
                    ELSE
                        v_title := 'Ride Completed 🎉';
                        v_body := E'Your ride has been completed successfully.\n\nThank you for choosing WayDrop.';
                    END IF;
                END IF;
            ELSIF p_order_type = 'ride' THEN
                v_title := 'Ride Completed 🎉';
                v_body := 'Your ride is completed. Thank you for riding with WayDrop. We hope to see you again!';
            ELSE
                v_title := 'Order Delivered Successfully 🎉';
                v_body := 'Your order has been completed. Rate your experience and thank the rider!';
            END IF;
        ELSIF p_new_status = 'cancelled' THEN
            -- Issue 7 fix: intercity-only actor-aware wording. Every other case (non-intercity, or
            -- p_cancelled_by NULL/unknown -- any caller not yet passing it) falls through to the
            -- exact original generic copy, unchanged.
            IF v_is_intercity AND p_cancelled_by = 'rider' THEN
                v_title := 'Trip Cancelled ❌';
                v_body := 'Sorry, your Traveller cancelled the trip.';
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
                        WHEN v_is_intercity AND p_cancelled_by = 'passenger' THEN 'The passenger cancelled the trip.'
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

-- =====================================================================================
-- 3. on_order_status_update(): thread NEW.cancelled_by through as the new trailing parameter.
--    Everything else preserved byte-for-byte from 20260810000000.
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
                        'p_cancelled_by', NEW.cancelled_by
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

-- =====================================================================================
-- 4. cascade_cancel_travel_plan_dependents(): tag the direct orders UPDATE with
--    cancelled_by = 'rider' (the Traveller cancelling their own plan is the actor for every order
--    this cascades to). Everything else preserved byte-for-byte from 20260729000003.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.cascade_cancel_travel_plan_dependents()
RETURNS TRIGGER AS $$
DECLARE
    v_now timestamptz := now();
BEGIN
    IF NEW.status = 'cancelled'::public.travel_plan_status_enum
       AND OLD.status IS DISTINCT FROM 'cancelled'::public.travel_plan_status_enum THEN

        -- Every still-open negotiation/booking on this plan -- never a row already in a terminal
        -- state (completed/cancelled/rejected/expired), and never in_progress (the guard above
        -- already refused the update if one exists).
        UPDATE public.intercity_requests
        SET status = 'cancelled',
            metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('cancelled_reason', 'travel_plan_cancelled'),
            updated_at = v_now
        WHERE route_id = NEW.id
          AND status IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid');

        -- The underlying order for each request just cancelled above, but only if it's still this
        -- exact plan's own rider and still sitting at 'accepted' (never touches an order that has
        -- already moved past acceptance under some other status, or belongs to a different rider).
        UPDATE public.orders o
        SET order_status = 'cancelled'::public.order_status_enum,
            cancelled_at = v_now,
            cancel_reason = 'Traveller cancelled the travel plan.',
            cancelled_by = 'rider',
            updated_at = v_now
        FROM public.intercity_requests ir
        WHERE ir.route_id = NEW.id
          AND ir.parcel_id = o.id
          AND ir.status = 'cancelled'
          AND o.order_status = 'accepted'
          AND o.rider_id = NEW.rider_id;

        INSERT INTO public.order_status_history (order_id, previous_status, new_status, changed_by, notes)
        SELECT o.id, 'accepted', 'cancelled', 'system_travel_plan_cancelled',
               'Cancelled because the linked travel plan was cancelled by the traveller.'
        FROM public.orders o
        WHERE o.rider_id = NEW.rider_id
          AND o.order_status = 'cancelled'
          AND o.cancelled_at = v_now
          AND EXISTS (
              SELECT 1 FROM public.intercity_requests ir
              WHERE ir.route_id = NEW.id AND ir.parcel_id = o.id AND ir.status = 'cancelled'
          );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
