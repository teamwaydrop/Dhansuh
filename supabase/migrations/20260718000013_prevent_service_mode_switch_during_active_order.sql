-- Migration: Block a partner from switching Service Mode while they have an
-- active order in progress.
-- Date: 2026-07-18
--
-- Service Mode is fully self-service (no admin approval) and changeable
-- anytime from Profile/Settings. Without this guard, a rider could switch
-- mode mid-trip (e.g. right after being assigned a local ride, flip to
-- 'intercity' before completing it), which the rest of the app's
-- active-order screens/state do not expect. Mirrors the existing
-- check_payout_update_limit trigger pattern (BEFORE UPDATE, business-rule
-- rejection via RAISE EXCEPTION) already used in this codebase for a
-- similar "don't let a rider change this while X is in flight" rule.

CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()
RETURNS TRIGGER AS $$
DECLARE
    v_active_orders_count integer;
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_active_orders_count
    FROM public.orders
    WHERE rider_id = NEW.id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing');

    IF v_active_orders_count > 0 THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while an order is active. Complete or cancel your current order first.'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE TRIGGER trigger_prevent_service_mode_switch_during_active_order
    BEFORE UPDATE OF service_mode ON public.riders
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_service_mode_switch_during_active_order();
