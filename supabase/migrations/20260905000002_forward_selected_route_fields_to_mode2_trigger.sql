-- Migration: forward selected-route fields to match-intercity-riders' Mode 2 trigger payload
-- Date: 2026-09-05
--
-- FROZEN SPEC (docs/13_Business_Logic.md section 5): the Mode 2 background-matching trigger
-- (on_rider_travel_plan_insert(), originally defined in
-- 20260901000031_travel_plan_insert_triggers_matching_server_side.sql) builds its request body
-- via an explicit jsonb_build_object(...) field list, not a full-row serialization -- so the
-- three columns added by 20260905000001_add_selected_route_columns.sql
-- (selected_route_geometry, selected_route_meta, route_selection_status) are structurally
-- invisible to it until this function is explicitly updated to forward them.
--
-- This migration is a PURE ADDITIVE PAYLOAD EXTENSION: CREATE OR REPLACE FUNCTION with the
-- exact same body as the original migration, plus the three new keys added to the existing
-- jsonb_build_object('plan', ...) call. Nothing else changes:
--   - trigger timing: still AFTER INSERT, unchanged (this migration does not touch the
--     CREATE TRIGGER statement at all -- the existing trigger already dispatches to this
--     function by name, so redefining the function is sufficient)
--   - HTTP invocation mechanism: still net.http_post to the same URL, same timeout
--   - existing payload fields: all 15 original keys (id, rider_id, pickup_lat, pickup_lng,
--     destination_lat, destination_lng, weight_preference, max_weight_kg, travel_plan_type,
--     vehicle_type, max_bookings, pickup_city, destination_city, travel_date, route_geometry)
--     are byte-for-byte unchanged
--   - authentication behavior: still the vault-sourced service_role_key, same lookup
--   - matching invocation behavior (is_background: true): unchanged
--   - the status='active' guard, exception handling, and RAISE WARNING messages: unchanged
--
-- For plans created before this migration (or for any plan where these columns are NULL),
-- jsonb_build_object simply emits a JSON null for these three keys -- exactly like every other
-- nullable field already in this payload (e.g. vehicle_type can already be NULL) -- so Mode 2's
-- own selected_route_geometry-presence guard in match-intercity-riders/index.ts (added in a
-- prior task) continues to skip the shadow block for them, unchanged.
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
                        'route_geometry', NEW.route_geometry,
                        -- Additive only (this migration's sole change): FROZEN SPEC,
                        -- docs/13_Business_Logic.md section 5.2/5.3. NULL for any plan that
                        -- predates this feature or has no selection -- matches how every other
                        -- nullable field above already behaves.
                        'selected_route_geometry', NEW.selected_route_geometry,
                        'selected_route_meta', NEW.selected_route_meta,
                        'route_selection_status', NEW.route_selection_status
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
