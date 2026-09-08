-- Migration: Issue 7 (Phase 2) -- USER did not receive the Traveller Match notification when the
-- USER's request/order was created FIRST and a matching Traveller Travel Plan was posted LATER
-- ("USER FIRST"), even though the reverse order ("TRAVELLER FIRST": plan posted first, user's
-- order created later) already worked correctly.
--
-- TRACE (both directions reproduced live against a local Supabase/Docker instance, not assumed):
--   match-intercity-riders/index.ts already implements BOTH directions symmetrically and
--   CORRECTLY at the matching-logic level:
--     - Mode 1 (order_id): searches existing rider_travel_plans for a newly created order, sends
--       sendTravellerAvailableNotifications() to the order's own user_id for every genuinely new,
--       verified match.
--     - Mode 2 (plan): searches existing searching orders for a newly posted travel plan, sends the
--       SAME sendTravellerAvailableNotifications() to each matched order's user_id.
--   Calling Mode 2 directly (exactly the body post_travel_plan_screen.dart sends) against a
--   pre-existing matching order produced the correct "Traveller Available" notification for the
--   user, proving the MATCHING LOGIC ITSELF is not the bug in either direction.
--
--   THE REAL ASYMMETRY IS IN WHO GUARANTEES THE BACKGROUND CALL ACTUALLY RUNS:
--     - Mode 1 is invoked from INSIDE create-order/index.ts (an edge function) via a
--       server-to-server fetch() wrapped in `EdgeRuntime.waitUntil(backgroundPromise)` -- this
--       keeps running on Deno's own infrastructure even after create-order has already returned
--       its HTTP response, completely independent of the calling client's process lifetime.
--     - Mode 2 was invoked directly from the FLUTTER CLIENT (post_travel_plan_screen.dart) as a
--       bare `unawaited(() async { await supabase.functions.invoke(...) })` Future, tied entirely
--       to the app process. rider_travel_plans is created via a direct client-side `.insert()` --
--       there is no edge function boundary for plan creation to attach a waitUntil-style guarantee
--       to. The moment a rider backgrounds/closes the app right after seeing "Travel plan posted
--       successfully!" (the success SnackBar already fired, so this is a completely natural next
--       action) -- a very real and unpredictable window, not a rare edge case -- the in-flight HTTP
--       request can be dropped before the server ever processes it, and the notification to
--       whichever user(s) were already waiting on this exact route is silently never sent. Nothing
--       else in this codebase retries a dropped Mode 2 call; there is no cron backstop for it
--       (unlike local-ride dispatch's redispatch_freed_riders()/redispatch_stalled_searching_
--       orders()).
--
-- FIX: move the trigger for Mode 2 from the Flutter client to the database itself, mirroring the
-- exact server-guaranteed pattern this schema already uses for every other "a DB write must
-- reliably kick off an edge function call" case (on_order_status_update(),
-- assign_new_order_to_nearby_online_riders(), deliver_push_notification_http_fnc() -- all call an
-- HTTP endpoint via pg_net.http_post() from an AFTER trigger, non-blocking, exception-isolated). A
-- new AFTER INSERT trigger on rider_travel_plans now calls match-intercity-riders itself, in the
-- SAME Mode-2 shape post_travel_plan_screen.dart used to send, authenticated with the service role
-- key (exactly how create-order's own Mode 1 call already authenticates) -- so it fires reliably
-- from Postgres's own commit, regardless of what the rider's app does immediately afterward. The
-- now-redundant client-side call is removed from post_travel_plan_screen.dart (a companion Flutter
-- change) so the match is never computed twice for the same plan.
--
-- No matching ELIGIBILITY rule changes at all (radius, vehicle, weight, date window, verified-only
-- gate, dedup-by-(order_id,plan_id) via travel_matches) -- match-intercity-riders/index.ts itself is
-- completely untouched by this migration. This is purely a "who reliably triggers it" fix.
CREATE OR REPLACE FUNCTION public.on_rider_travel_plan_insert()
RETURNS trigger AS $$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    -- Mirrors match-intercity-riders' own Mode 2 gating: only a plan that is actually live/
    -- searchable is worth matching. A plan can only ever be inserted as 'active' in practice (no
    -- existing insert path creates one pre-cancelled), but this guard costs nothing and protects
    -- against any future insert path that might.
    IF NEW.status != 'active' THEN
        RETURN NEW;
    END IF;

    BEGIN
        SELECT decrypted_secret INTO v_service_role_key
        FROM vault.decrypted_secrets
        WHERE name = 'supabase_service_role_key'
        LIMIT 1;

        IF v_service_role_key IS NOT NULL THEN
            PERFORM net.http_post(
                url := v_supabase_url || '/functions/v1/match-intercity-riders',
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || v_service_role_key
                ),
                body := jsonb_build_object(
                    'plan', jsonb_build_object(
                        'id', NEW.id,
                        'rider_id', NEW.rider_id,
                        'pickup_lat', NEW.pickup_lat,
                        'pickup_lng', NEW.pickup_lng,
                        'destination_lat', NEW.destination_lat,
                        'destination_lng', NEW.destination_lng,
                        'weight_preference', NEW.weight_preference,
                        'max_weight_kg', NEW.max_weight_kg,
                        'travel_plan_type', NEW.travel_plan_type,
                        'vehicle_type', NEW.vehicle_type,
                        'max_bookings', NEW.max_bookings,
                        'pickup_city', NEW.pickup_city,
                        'destination_city', NEW.destination_city,
                        'travel_date', NEW.travel_date,
                        'route_geometry', NEW.route_geometry
                    ),
                    'is_background', true
                ),
                timeout_milliseconds := 8000
            );
        ELSE
            RAISE WARNING 'on_rider_travel_plan_insert: vault secret "supabase_service_role_key" is not configured -- skipping async traveller-plan match for plan %', NEW.id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Never block the plan's own creation on the async enqueue itself failing.
        RAISE WARNING 'on_rider_travel_plan_insert: failed to enqueue async traveller-plan match for plan %: %', NEW.id, SQLERRM;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_on_rider_travel_plan_insert ON public.rider_travel_plans;
CREATE TRIGGER trigger_on_rider_travel_plan_insert
AFTER INSERT ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.on_rider_travel_plan_insert();
