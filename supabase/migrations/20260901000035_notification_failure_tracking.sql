-- =====================================================================
-- PHASE 6 (CORE SCOPE ONLY): notification pipeline failure tracking.
-- =====================================================================
-- AUDIT SUMMARY (see conversation report for the full read-only audit): the notification
-- pipeline -- orders trigger -> pg_net -> send_order_status_notifications_core ->
-- send_push_notification_fnc -> INSERT INTO notifications -> pg_net -> send-push-notification
-- Edge Function -> FCM -- has a proven, currently-live silent-failure zone. Live evidence at
-- audit time: 378 rows sitting in notifications.delivery_status='pending' for over an hour (some
-- for ~8 weeks), because nothing in this chain ever persists a failure -- every failure point is
-- either an unhandled exception (send_order_status_notifications_core, send_push_notification_fnc)
-- or a RAISE WARNING that only reaches Supabase's ephemeral function/Postgres logs
-- (deliver_push_notification_http_fnc, on_order_status_update). Two historical incidents
-- (20260718000000, 20260718000002) were each a complete, silent, app-wide notification outage
-- discovered only by a human manually diffing pg_get_functiondef against production -- this
-- migration would have made both queryable within minutes of the first failed attempt.
--
-- SCOPE: this migration implements ONLY the explicitly approved core fix:
--   1. CREATE TABLE public.notification_failures (new, additive, RLS-protected).
--   2. Add a failure-branch INSERT into that table to exactly four existing functions:
--      deliver_push_notification_http_fnc, on_order_status_update,
--      send_order_status_notifications_core (the live 11-arg overload only -- see note below),
--      send_push_notification_fnc.
--   3. Every change is additive to an existing (or newly-added) EXCEPTION branch only -- zero
--      lines of existing success-path logic are modified, reordered, or removed in any of the
--      four functions. Diff each function against its pre-migration pg_get_functiondef to verify.
--
-- EXPLICITLY NOT IN SCOPE for this migration (per the approval, deferred to a separate decision):
--   - on_intercity_request_change and on_rider_review_insert are NOT modified. Both currently call
--     send_push_notification_fnc() synchronously, with no exception handling of their own -- a
--     notification failure there can still, today, roll back the real business transaction
--     (a rating submission or an intercity request response). This migration does NOT fix that
--     directly. NOTE, disclosed explicitly: because send_push_notification_fnc's own INSERT is now
--     wrapped (item 4, approved), an exception raised by that INSERT is caught INSIDE
--     send_push_notification_fnc itself and never reaches ANY caller, including these two
--     unmodified trigger functions -- so as a side effect of the approved fix to the shared
--     function, notification-insert failures originating from these two paths also stop breaking
--     their business transaction, without either trigger function's own source being touched.
--     This is disclosed in the conversation report as a callout requiring explicit attention, not
--     hidden.
--   - No retry mechanism. No alerting. No kill switch. No change to notification title/body/type/
--     recipient/routing/payload/timing on the success path. No Edge Function change. No Flutter
--     change.
--   - send_order_status_notifications_core has TWO live overloads in the schema: a 9-arg version
--     (oid 30446 at audit time) that is dead code -- never invoked by any current trigger -- and
--     the 11-arg version (adds p_cancelled_by/p_cancel_reason) that on_order_status_update's
--     PostgREST RPC call actually resolves to. Only the live 11-arg overload is modified here; the
--     dead 9-arg overload is left untouched (fixing dead code provides no real observability
--     value and is out of the approved scope).
-- =====================================================================

-- =====================================================================
-- 1. notification_failures table
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.notification_failures (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- One of the four stages this fix can distinguish, per the audited design:
    --   enqueue        -- the vault secret is missing, or the net.http_post enqueue call itself
    --                      threw (deliver_push_notification_http_fnc, on_order_status_update).
    --   processing      -- send_order_status_notifications_core threw before ever reaching
    --                      send_push_notification_fnc (or one of its own calls to it failed and
    --                      was not independently caught closer to the source).
    --   insert          -- send_push_notification_fnc's own INSERT INTO notifications threw.
    --   push_delivery   -- deliver_push_notification_http_fnc's net.http_post call to
    --                      send-push-notification threw (the notification row already exists by
    --                      this point).
    failure_stage text NOT NULL CHECK (failure_stage IN ('enqueue', 'processing', 'insert', 'push_delivery')),

    -- Which function detected/logged the failure -- always a literal, hardcoded string at each
    -- call site, never user input.
    source_function text NOT NULL,

    -- Best-effort diagnostic context, deliberately all nullable -- an early-stage failure (e.g.
    -- enqueue) may occur before some of these are even known.
    notification_type text,
    reference_id uuid,
    user_id uuid,
    -- Only ever populated once a real public.notifications row exists (push_delivery-stage
    -- failures) -- ON DELETE SET NULL so this table never blocks a notifications row from being
    -- pruned/deleted in the future.
    notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL,

    -- Bounded, structured error context only -- never a payload, token, secret, or OTP. Every
    -- INSERT into this table in this migration uses SQLSTATE/left(SQLERRM, 2000) or a fixed
    -- literal string, never p_data/NEW.* wholesale.
    error_code text,
    error_message text,

    -- The pg_net request id, when available. NOTE (disclosed, not hidden): under this migration's
    -- scope, a failure logged here almost always means net.http_post either wasn't reached (vault
    -- missing) or threw during the call itself -- in both cases no request id was ever obtained,
    -- so this column will typically be NULL in practice. It costs nothing to capture opportunistically
    -- and is kept for schema completeness per the approved design and for any future, separately-
    -- approved correlation work against net._http_response.
    pg_net_request_id bigint,

    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notification_failures_created_at ON public.notification_failures (created_at);
CREATE INDEX IF NOT EXISTS idx_notification_failures_stage ON public.notification_failures (failure_stage);
CREATE INDEX IF NOT EXISTS idx_notification_failures_reference_id ON public.notification_failures (reference_id);

-- ---------------------------------------------------------------
-- RLS: mirrors dispatch_config/pricing_config's already-audited, already-proven pattern exactly
-- (verified live via pg_policies during this phase's audit) -- admin-only SELECT, no INSERT/
-- UPDATE/DELETE policy for anyone but service_role (RLS default-deny covers that automatically).
-- ---------------------------------------------------------------
ALTER TABLE public.notification_failures ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can view notification failures"
    ON public.notification_failures
    FOR SELECT
    TO authenticated
    USING (public.is_admin());

GRANT SELECT ON public.notification_failures TO authenticated;
GRANT ALL ON public.notification_failures TO service_role;


-- =====================================================================
-- 2. deliver_push_notification_http_fnc -- add enqueue/push_delivery-stage failure tracking.
-- Every line of existing logic below is byte-for-byte unchanged; only the two failure branches
-- (vault-secret-missing, and the EXCEPTION handler) gain a self-contained, independently-guarded
-- INSERT. The success path (vault secret present, net.http_post does not throw) is completely
-- untouched and incurs zero new writes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
    v_notification_id uuid;
BEGIN
    -- Phase 6: best-effort extraction for failure-tracking context only -- never affects delivery,
    -- and a bad/missing value here can never abort the function (guarded sub-block).
    BEGIN
        v_notification_id := NULLIF(p_data->>'notification_id', '')::uuid;
    EXCEPTION WHEN OTHERS THEN
        v_notification_id := NULL;
    END;

    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_service_role_key'
    LIMIT 1;

    IF v_service_role_key IS NULL THEN
        RAISE WARNING 'Push notification delivery skipped: vault secret "supabase_service_role_key" is not configured. Run vault.create_secret(...) once via the Supabase Dashboard SQL Editor.';
        BEGIN
            INSERT INTO public.notification_failures (
                failure_stage, source_function, notification_type, reference_id, user_id,
                notification_id, error_message
            ) VALUES (
                'enqueue', 'deliver_push_notification_http_fnc', p_data->>'type',
                NULLIF(p_data->>'reference_id', '')::uuid, p_user_id, v_notification_id,
                'vault secret "supabase_service_role_key" is not configured'
            );
        EXCEPTION WHEN OTHERS THEN
            -- Failure-tracking must never itself introduce a new failure mode.
            NULL;
        END;
        RETURN;
    END IF;

    PERFORM net.http_post(
        url := v_supabase_url || '/functions/v1/send-push-notification',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key
        ),
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;
    BEGIN
        INSERT INTO public.notification_failures (
            failure_stage, source_function, notification_type, reference_id, user_id,
            notification_id, error_code, error_message
        ) VALUES (
            'push_delivery', 'deliver_push_notification_http_fnc', p_data->>'type',
            NULLIF(p_data->>'reference_id', '')::uuid, p_user_id, v_notification_id,
            SQLSTATE, left(SQLERRM, 2000)
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$function$;


-- =====================================================================
-- 3. on_order_status_update -- add enqueue-stage failure tracking.
-- Every line of existing logic below is byte-for-byte unchanged; only the "vault secret missing"
-- ELSE branch and the outer EXCEPTION handler gain a self-contained, independently-guarded INSERT.
-- The success path (vault secret present, net.http_post does not throw) is completely untouched
-- and incurs zero new writes. RETURN NEW still happens unconditionally, exactly as before -- this
-- can never block the orders UPDATE itself.
-- =====================================================================
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
                BEGIN
                    INSERT INTO public.notification_failures (
                        failure_stage, source_function, notification_type, reference_id, user_id,
                        error_message
                    ) VALUES (
                        'enqueue', 'on_order_status_update', 'order_status', NEW.id, NEW.user_id,
                        'vault secret "supabase_service_role_key" is not configured'
                    );
                EXCEPTION WHEN OTHERS THEN
                    NULL;
                END;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'on_order_status_update: failed to enqueue async notification for order %: %', NEW.id, SQLERRM;
            BEGIN
                INSERT INTO public.notification_failures (
                    failure_stage, source_function, notification_type, reference_id, user_id,
                    error_code, error_message
                ) VALUES (
                    'enqueue', 'on_order_status_update', 'order_status', NEW.id, NEW.user_id,
                    SQLSTATE, left(SQLERRM, 2000)
                );
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
    END IF;

    RETURN NEW;
END;
$function$;


-- =====================================================================
-- 4. send_order_status_notifications_core (live 11-arg overload only) -- add processing-stage
-- failure tracking. This function previously had NO exception handling at all -- every line of
-- its existing body (all notification-copy branches, all three send_push_notification_fnc call
-- sites) is reproduced byte-for-byte unchanged below; only a new EXCEPTION clause is appended to
-- the function's own top-level block. Runs via its own PostgREST-invoked transaction (never the
-- orders UPDATE's transaction), so this was already incapable of blocking the real order update --
-- this migration only makes its failures visible instead of vanishing without a trace.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.send_order_status_notifications_core(p_order_id uuid, p_old_status text, p_new_status text, p_order_type text, p_estimated_duration_min integer, p_pickup_otp text, p_delivery_otp text, p_user_id uuid, p_rider_id uuid, p_cancelled_by text DEFAULT NULL::text, p_cancel_reason text DEFAULT NULL::text)
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
                        -- THIS MIGRATION (Issue 6): kept consistent with
                        -- on_intercity_request_change()'s 'in_progress' branch above -- the parcel
                        -- has not been picked up yet at this point.
                        v_title := 'Traveller Heading to Pickup 🚚';
                        v_body := E'Your traveller has started the trip and is heading towards you to pick up the parcel.\n\nTrack it live in the WayDrop app.';
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
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'send_order_status_notifications_core: failed for order %: %', p_order_id, SQLERRM;
    BEGIN
        INSERT INTO public.notification_failures (
            failure_stage, source_function, notification_type, reference_id, user_id,
            error_code, error_message
        ) VALUES (
            'processing', 'send_order_status_notifications_core', 'order_status', p_order_id, p_user_id,
            SQLSTATE, left(SQLERRM, 2000)
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$function$;


-- =====================================================================
-- 5. send_push_notification_fnc -- add insert-stage failure tracking.
-- Every line of existing logic below is byte-for-byte unchanged (including the pre-existing,
-- unrelated, benign UUID-parse swallow blocks); only a new EXCEPTION clause is appended to the
-- function's own top-level block, around the actual INSERT INTO notifications. The success path
-- (INSERT succeeds) is completely untouched and incurs zero new writes.
--
-- DISCLOSED SIDE EFFECT (see the header note above): on_intercity_request_change and
-- on_rider_review_insert both call this function directly and synchronously with no exception
-- handling of their own. Because this function's INSERT is now wrapped, an exception here is
-- caught HERE and never reaches those two callers -- meaning a notification-insert failure
-- originating from either path no longer breaks the real business transaction (a rating
-- submission, an intercity request response), even though neither trigger function's own source
-- is modified by this migration.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_notification_type text := COALESCE(p_data->>'type', 'general');
    v_reference_id uuid := NULL;
    v_reference_type text := NULL;
BEGIN
    -- Extract reference info if present
    IF p_data ? 'order_id' THEN
        BEGIN
            v_reference_id := (p_data->>'order_id')::uuid;
            v_reference_type := 'order';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    ELSIF p_data ? 'payment_id' THEN
        BEGIN
            v_reference_id := (p_data->>'payment_id')::uuid;
            v_reference_type := 'payment';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    END IF;

    -- Insert into notifications log table (which triggers async HTTP delivery)
    INSERT INTO public.notifications (
        user_id,
        title,
        body,
        notification_type,
        reference_id,
        reference_type,
        payload
    ) VALUES (
        p_user_id,
        p_title,
        p_body,
        v_notification_type,
        v_reference_id,
        v_reference_type,
        p_data
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'send_push_notification_fnc: failed to insert notification for user %: %', p_user_id, SQLERRM;
    BEGIN
        INSERT INTO public.notification_failures (
            failure_stage, source_function, notification_type, reference_id, user_id,
            error_code, error_message
        ) VALUES (
            'insert', 'send_push_notification_fnc', v_notification_type, v_reference_id, p_user_id,
            SQLSTATE, left(SQLERRM, 2000)
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
END;
$function$;
