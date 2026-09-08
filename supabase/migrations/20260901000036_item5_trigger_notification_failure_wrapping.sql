-- =====================================================================
-- PHASE 6 ITEM 5 (approved separately from the core Phase-6 migration 20260901000035):
-- wrap the notification-construction-and-send logic in on_intercity_request_change and
-- on_rider_review_insert so a notification failure can never roll back the underlying
-- business transaction (an intercity request insert/update, or a rating/review insert).
-- =====================================================================
-- WHY THIS IS STILL NEEDED after 20260901000035:
-- send_push_notification_fnc's own INSERT INTO public.notifications is now wrapped in that
-- migration, so an exception from THAT specific statement no longer reaches these two callers.
-- But the residual exposure is upstream of that call, inside these two trigger functions
-- themselves: the SELECT lookups (rider/user names, travel-plan cities), string concatenation,
-- and jsonb_build_object() calls used to build the notification title/body/payload all run with
-- no exception handling of their own today. Any failure there -- e.g. an unexpected NULL, a
-- lookup returning no/multiple rows in an edge case, a future data-shape change -- raises
-- directly out of the trigger and aborts the real row change (the intercity_requests
-- insert/update, or the rider_reviews insert), which is exactly the business-transaction
-- rollback this item exists to prevent.
--
-- Deliberately NOT caught: QUERY_CANCELED / ASSERT_FAILURE. PL/pgSQL's `WHEN OTHERS` never
-- matches these two conditions by design, and that is intentional here too -- swallowing a
-- query cancellation would defeat an operator's ability to cancel a stuck/long-running
-- statement. This migration does not attempt to catch them; that residual risk is accepted
-- and documented, not fixed.
--
-- SCOPE: only these two functions are changed. Every existing line of business logic (recipient
-- resolution, title/body copy, jsonb payload shape, RLS-adjacent self-notify guard) is
-- reproduced byte-for-byte unchanged -- the only addition is the surrounding
-- BEGIN ... EXCEPTION WHEN OTHERS ... END guard (mirroring the exact pattern already used for
-- on_order_status_update in 20260901000035) plus an unconditional RETURN NEW after it. The
-- failure-tracking INSERT itself is wrapped in its own nested BEGIN/EXCEPTION so a failure while
-- recording the failure can never escape either. No new table, no new trigger, no new
-- notification_failures.failure_stage value ('enqueue' is reused, matching the existing
-- on_order_status_update convention for a trigger-side enqueue/dispatch failure).
-- =====================================================================

-- 1. on_intercity_request_change -- guard the entire recipient/title/body decision tree and all
-- send_push_notification_fnc call sites (main match/status notification, the two rejected-path
-- notifications, and the confirmed-path notification to the rider).
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
                    v_title := 'Traveller Heading to Pickup 🚚';
                    v_body := E'Your traveller has started the trip and is heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app.';
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
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'on_intercity_request_change: failed to process/send notification for request %: %', NEW.id, SQLERRM;
        BEGIN
            INSERT INTO public.notification_failures (
                failure_stage, source_function, notification_type, reference_id, user_id,
                error_code, error_message
            ) VALUES (
                'enqueue', 'on_intercity_request_change', 'intercity_request', NEW.id, v_passenger_user_id,
                SQLSTATE, left(SQLERRM, 2000)
            );
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END;

    RETURN NEW;
END;
$function$;


-- 2. on_rider_review_insert -- guard the recipient/title/body decision tree, the feedback-comment
-- append, and the single send_push_notification_fnc call site.
CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_title text;
    v_body text;
BEGIN
    BEGIN
        IF NEW.rated_by = 'rider' THEN
            -- Traveller/Drop Partner rated the passenger -> the PASSENGER is the recipient. NEW.user_id
            -- is the order's passenger column directly -- never derived from anything client-supplied.
            v_recipient_user_id := NEW.user_id;

            IF NEW.rating = 5 THEN
                v_title := 'You''ve been rated 5-Star! 🌟';
                v_body := 'Your Drop Partner rated your trip 5 stars!';
            ELSE
                v_title := 'New Rating Received';
                v_body := 'Your Drop Partner rated your trip.';
            END IF;
        ELSE
            -- Passenger rated the traveller (rated_by = 'user', the original/default direction) -> the
            -- TRAVELLER is the recipient, resolved via riders.user_id from NEW.rider_id (unchanged from
            -- the original, correct behavior for this direction).
            SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;

            IF NEW.rating = 5 THEN
                v_title := 'You''ve been rated 5-Star! 🌟';
                v_body := 'Excellent job! Your passenger rated your trip 5 stars. Keep up the amazing work!';
            ELSE
                v_title := 'New Rating Received';
                v_body := 'Your passenger rated their trip with you.';
            END IF;
        END IF;

        IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
            v_body := v_body || ' Feedback: "' || NEW.comment || '"';
        ELSE
            v_body := v_body || ' Feedback: "No written feedback provided."';
        END IF;

        -- Defense in depth: the rating's submitter must never be its own recipient. auth.uid() here is
        -- the actual authenticated inserter (enforced to match rated_by by the existing "Users/Riders
        -- can insert reviews for their own orders" RLS policies), so this can never fire for a
        -- legitimate insert -- it only guards against a future regression re-introducing self-notify.
        IF v_recipient_user_id IS NOT NULL AND v_recipient_user_id IS DISTINCT FROM auth.uid() THEN
            PERFORM public.send_push_notification_fnc(
                v_recipient_user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'new_rating',
                    'rating', NEW.rating,
                    'review_id', NEW.id,
                    'order_id', NEW.order_id,
                    'rated_by', NEW.rated_by
                )
            );
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'on_rider_review_insert: failed to process/send notification for review %: %', NEW.id, SQLERRM;
        BEGIN
            INSERT INTO public.notification_failures (
                failure_stage, source_function, notification_type, reference_id, user_id,
                error_code, error_message
            ) VALUES (
                'enqueue', 'on_rider_review_insert', 'new_rating', NEW.id, NEW.user_id,
                SQLSTATE, left(SQLERRM, 2000)
            );
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END;

    RETURN NEW;
END;
$function$;
