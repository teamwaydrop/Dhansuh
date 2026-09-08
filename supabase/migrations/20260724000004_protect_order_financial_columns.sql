-- Migration: Database-level protection against direct tampering with an order's financial
-- split columns (commission, GST, driver earning).
-- Date: 2026-07-24
--
-- CONTEXT: the "boost fare while searching" feature was just moved from client-computed direct
-- table writes to the server-authoritative boost-order-fare edge function. But RLS is row-level
-- only -- the existing "user_can_update_own_order" policy (auth.uid() = user_id AND
-- order_status = 'searching') combined with the blanket UPDATE grant to `authenticated` still lets
-- a raw PATCH request (bypassing the app entirely, e.g. a modified client or a direct REST call)
-- set commission_amount, gst_amount, rider_earning, etc. to anything at all on an order the caller
-- legitimately owns. This trigger closes that regardless of which app code path is used.
--
-- Scope: only the true revenue-split columns are protected (commission/GST/rider-earning/
-- actual_fare and their boost-derived counterparts). current_fare/final_fare/boost_amount/
-- boost_percentage are intentionally left writable by 'authenticated' -- the existing intercity
-- chat fare-negotiation feature (order_chat_screen.dart) legitimately updates a NEGOTIATED fare
-- directly, and that is a separate, pre-existing feature this migration does not change.
CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    -- Our edge functions (create-order, update-order-status, boost-order-fare, ...) connect using
    -- the service role key, which authenticates at the database level as 'service_role' -- the
    -- only caller ever allowed to change these columns. Any other caller (an 'authenticated' user
    -- hitting PostgREST directly, with or without going through the app's own UI) is rejected here
    -- regardless of whether the row-level RLS check would otherwise have allowed the update.
    IF auth.role() <> 'service_role' THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS protect_order_financial_columns_trigger ON public.orders;
CREATE TRIGGER protect_order_financial_columns_trigger
BEFORE UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.protect_order_financial_columns();
