-- Migration: fix wrong-actor wording on the notification a passenger gets when THEY cancel their
-- own intercity Travel Request/booking before or after a Traveller has accepted it.
--
-- ROOT CAUSE (traced end to end): update-order-status/index.ts's "SYNC THE LINKED
-- intercity_requests NEGOTIATION ROW TO MATCH THE ORDER'S TERMINAL STATE" block (added by the P2
-- fix documented in that file) runs for EVERY cancellation of an intercity_ride/intercity_parcel
-- order -- regardless of whether the PASSENGER or the RIDER (traveller) was the one who cancelled
-- it -- and does a plain `UPDATE intercity_requests SET status = 'cancelled', updated_at = ...`
-- with no actor information attached at all. That UPDATE fires the existing
-- on_intercity_request_change() trigger's 'cancelled' branch (20260901000004), which -- whenever
-- neither metadata->>'cancelled_scope' key is set (true for every row this sync block touches,
-- since it is a completely separate write path from cancel_travel_plan_by_traveller() and
-- cancel_intercity_request_by_traveller(), the only two writers that ever set that key) -- falls
-- through to the original generic copy: "Your traveller cancelled this trip. Please choose another
-- available partner.", sent to the PASSENGER (v_notify_user_id := v_passenger_user_id).
--
-- So when the passenger cancels their OWN still-pending or already-accepted intercity booking,
-- they are told a traveller cancelled it -- attributing the passenger's own action to the other
-- party. When the RIDER cancels the order through this same generic update-order-status path
-- (rather than through cancel_travel_plan_by_traveller), the existing "Your traveller cancelled"
-- wording is already correct (a different person really did perform the action) and must be left
-- exactly as-is -- this migration does NOT touch that case, or either of the two existing
-- 'cancelled_scope' branches, or any other status branch, or any ride/local-parcel notification.
--
-- FIX (two parts):
--   1. New `intercity_requests.cancelled_by_actor` column (additive, nullable) -- set directly by
--      update-order-status/index.ts, in the SAME update as the status sync, from the already-
--      resolved server-side isDriver/isPassenger (never a client-supplied value, mirroring exactly
--      how orders.cancelled_by is already derived a few hundred lines earlier in that file). A
--      dedicated column instead of merging into the existing `metadata` jsonb: that column already
--      carries independent keys (sender_agreed/traveller_agreed/rejected_by/cancelled_scope) used
--      by several other branches, and a naive client-side overwrite of the whole object here would
--      risk silently dropping whichever of those keys happened to be set at cancel time.
--   2. on_intercity_request_change()'s 'cancelled' branch gains ONE new, highest-priority check:
--      NEW.cancelled_by_actor = 'user' -> "You cancelled this request." (correct self-
--      attribution). Every other condition (rejected_by IS NOT NULL, cancelled_scope = travel_plan/
--      individual_request, or the original generic ELSE) is reproduced byte-for-byte from
--      20260901000004 -- unset/NULL cancelled_by_actor (every row written by
--      cascade_cancel_travel_plan_dependents() or cancel_intercity_request_by_traveller(), which
--      never touch this new column) falls through to that exact preexisting logic, unchanged.
--
--   RECONCILED AGAINST ACTUAL PRODUCTION (2026-08-23, read-only verification): this column is
--   brand-new (no enum constraint of its own), so a 'passenger' sentinel would not have raised a
--   database error -- but a read-only audit of the LINKED production project's
--   send_order_status_notifications_core() found that orders.cancelled_by (the sibling column
--   this migration's own header explicitly mirrors) is the real Postgres enum cancelled_by_enum
--   ('user' | 'rider' | 'admin' | 'system') -- there is no 'passenger' label anywhere in this
--   codebase's actual actor-attribution convention. The sentinel below was corrected from the
--   original draft's 'passenger' to 'user' to match that established convention exactly, before
--   this migration was ever deployed -- see 20260901000025's header for the full production
--   reconciliation trace this was discovered during.

-- =====================================================================================
-- 1. intercity_requests.cancelled_by_actor -- additive, nullable, forward-only.
-- =====================================================================================
ALTER TABLE public.intercity_requests ADD COLUMN IF NOT EXISTS cancelled_by_actor text;

-- =====================================================================================
-- 2. on_intercity_request_change(): one new actor-aware branch ahead of the existing
--    cancelled_scope checks. Every other branch preserved byte-for-byte from 20260901000004.
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
                v_title := 'Trip Started 🚚';
                v_body := E'Your traveller has started the trip with your parcel.\n\nTrack it live in the WayDrop app.';
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

                -- THIS MIGRATION: the passenger cancelled their OWN request/booking (via
                -- update-order-status, which now stamps cancelled_by_actor='user' in the same
                -- update that flips this row to 'cancelled' -- see that file's intercity_requests
                -- sync block). 'user' matches the actor label orders.cancelled_by (the sibling
                -- column) already uses in production -- there is no 'passenger' label anywhere in
                -- this codebase's actor convention (see the header's reconciliation note).
                -- Correct self-attribution: never blame "the traveller" for the passenger's own
                -- action. Checked ahead of the cancelled_scope branches below since this column is
                -- populated by an entirely different write path than either of them.
                IF NEW.cancelled_by_actor = 'user' THEN
                    v_title := 'Booking Cancelled';
                    v_body := 'You cancelled this request.';

                ELSIF NEW.metadata->>'cancelled_scope' = 'travel_plan' THEN
                    -- Issue 2: whole travel-plan cancellation. Distinct from the individual-request
                    -- message below -- names the actual traveller-supplied reason, never the
                    -- generic "cancelled this trip" copy.
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
                    -- Issue 1: traveller cancelled just this one accepted passenger; every other
                    -- passenger on the same plan is untouched. Route-aware, reason kept internal
                    -- (not exposed to the cancelled passenger), matching the specified wording.
                    v_title := 'Booking Cancelled';
                    IF v_plan_pickup IS NOT NULL AND v_plan_dest IS NOT NULL THEN
                        v_body := 'Your request for the travel plan from ' || v_plan_pickup || ' to ' || v_plan_dest
                            || ' was cancelled by the traveller. You can search for another available traveller.';
                    ELSE
                        v_body := 'Your request was cancelled by the traveller. You can search for another available traveller.';
                    END IF;

                ELSE
                    -- Preserved: any 'cancelled' transition not produced by any of the canonical
                    -- paths above (including a rider-initiated cancel through update-order-status,
                    -- where cancelled_by_actor='rider') keeps the exact original generic wording,
                    -- unchanged -- it really was the traveller who cancelled in that case.
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
                'status', NEW.status
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
