-- Migration: Non-bypassable Partner Service Mode enforcement via DB triggers.
-- Date: 2026-07-18
--
-- This is the real security/correctness boundary for the local/intercity
-- partner separation. Query-level filters added in
-- 20260718000010_enforce_service_mode_in_dispatch_functions.sql only stop
-- wrong-mode riders from being *offered* the wrong job through the two
-- known dispatch paths — they do nothing to stop a service-role Edge
-- Function (which bypasses RLS entirely) or any future code path from
-- writing a mode-mismatched assignment directly. Triggers fire
-- unconditionally regardless of caller role, so these two triggers are the
-- actual guarantee:
--
--   1. rider_assignments: BEFORE INSERT — blocks offering a job to a
--      wrong-mode rider in the first place.
--   2. orders: BEFORE UPDATE OF rider_id — blocks a job from actually being
--      confirmed to a wrong-mode rider, regardless of whether it arrived
--      via rider_assignments, accept-order, accept_intercity_request, or
--      any future path. This is the final backstop.
--
-- Both use get_required_service_mode() (20260718000009) as the single
-- source of truth for order classification, and both reject with a clear
-- message distinguishing "wrong mode" from "no mode chosen yet" (NULL).

CREATE OR REPLACE FUNCTION public.enforce_rider_assignment_service_mode()
RETURNS TRIGGER AS $$
DECLARE
    v_order_type text;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
    v_rider_mode public.partner_service_mode_enum;
BEGIN
    SELECT o.order_type::text, o.distance_meters
    INTO v_order_type, v_distance_meters
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    SELECT r.service_mode INTO v_rider_mode
    FROM public.riders r
    WHERE r.id = NEW.rider_id;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    IF v_rider_mode IS NULL THEN
        RAISE EXCEPTION 'Rider % has not selected a Service Mode yet and cannot be assigned any orders', NEW.rider_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rider_mode != v_required_mode THEN
        RAISE EXCEPTION 'Rider % service_mode (%) does not match the service mode required (%) for order %', NEW.rider_id, v_rider_mode, v_required_mode, NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE TRIGGER trigger_enforce_rider_assignment_service_mode
    BEFORE INSERT ON public.rider_assignments
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_rider_assignment_service_mode();

CREATE OR REPLACE FUNCTION public.enforce_order_rider_service_mode()
RETURNS TRIGGER AS $$
DECLARE
    v_required_mode public.partner_service_mode_enum;
    v_rider_mode public.partner_service_mode_enum;
BEGIN
    -- Only check when rider_id is being set/changed to a non-null value.
    IF NEW.rider_id IS NULL OR NEW.rider_id IS NOT DISTINCT FROM OLD.rider_id THEN
        RETURN NEW;
    END IF;

    SELECT r.service_mode INTO v_rider_mode
    FROM public.riders r
    WHERE r.id = NEW.rider_id;

    v_required_mode := public.get_required_service_mode(NEW.order_type::text, NEW.distance_meters);

    IF v_rider_mode IS NULL THEN
        RAISE EXCEPTION 'Rider % has not selected a Service Mode yet and cannot be assigned order %', NEW.rider_id, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rider_mode != v_required_mode THEN
        RAISE EXCEPTION 'Rider % service_mode (%) does not match the service mode required (%) for order %', NEW.rider_id, v_rider_mode, v_required_mode, NEW.id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE TRIGGER trigger_enforce_order_rider_service_mode
    BEFORE UPDATE OF rider_id ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_order_rider_service_mode();
