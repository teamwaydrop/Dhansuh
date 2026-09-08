-- Migration: Close a payment-amount-tampering gap -- lock orders.current_fare/final_fare/
-- boost_amount/boost_percentage to service_role (or explicitly-authorized SECURITY DEFINER RPC)
-- writes only.
-- Date: 2026-07-30
--
-- ROOT CAUSE (verified, not assumed): "Allow passengers and assigned riders to update orders"
-- (supabase/migrations/20260531000003_fix_find_nearby_riders.sql:232-244) is a row-level-only
-- UPDATE policy (USING: auth.uid()=user_id OR assigned rider; NO WITH CHECK, NO order_status
-- restriction) that remains live today alongside the narrower "user_can_update_own_order" policy
-- -- Postgres OR's RLS policies together, so the broader one governs. protect_order_financial_
-- columns (base: 20260724000004, current live definition: 20260725000002) already protects
-- commission_amount/gst_amount/rider_earning/commission_percentage/gst_percentage/actual_fare/
-- boost_rider_earning/boost_company_earning/payment_status/fare_payment_method, but has always
-- explicitly carved out current_fare/final_fare/boost_amount/boost_percentage as "intentionally
-- left writable by authenticated... the existing intercity chat fare-negotiation feature
-- (order_chat_screen.dart) legitimately updates a NEGOTIATED fare directly."
--
-- That carve-out is stale. order_chat_screen.dart's own in-code comments (around the "Accept"
-- button, and around the old direct-write block) confirm the negotiation flow was already
-- redesigned to go through confirm_intercity_booking() (a server-side RPC) instead, and explicitly
-- does NOT write current_fare/final_fare from the client anymore. A full grep of every
-- `.from('orders').update(...)` call site in lib/ (the only way the Flutter client ever writes to
-- this table directly) confirms zero of them touch current_fare, final_fare, boost_amount, or
-- boost_percentage -- every "boost" value passed from Flutter (e.g. max_boost_amount in booking
-- screens) is part of a create-order/boost-order-fare edge function request body (server-role,
-- unaffected by this trigger), never a direct table write.
--
-- Net effect of the current gap: create-payment/index.ts and create-fare-qr/index.ts both read
-- `orderRow.final_fare ?? orderRow.current_fare` straight from the table and charge exactly that
-- amount via Cashfree, with a comment claiming this is never client-trusted -- but the column
-- itself was directly writable by the paying passenger via a raw PostgREST PATCH (no app
-- modification needed, just their own valid JWT), letting them set their own fare to any amount
-- before paying it.
--
-- SAFETY CHECK (this is exactly the mistake 20260725000000 made, documented in 20260725000002's
-- own header as a real production incident: re-basing this CREATE OR REPLACE off an older
-- definition and silently dropping the `app.bypass_financial_guard` escape hatch, which broke
-- mark_fare_payment_attempted() for every personal_upi driver). Verified every current writer of
-- these 4 columns before adding them here:
--   - accept_intercity_request() (latest: 20260728000000) sets final_fare/current_fare, but is
--     ONLY ever invoked via supabase/functions/accept-intercity-request/index.ts, which connects
--     with SUPABASE_SERVICE_ROLE_KEY -- auth.role() = 'service_role' there, unaffected.
--   - confirm_intercity_booking() (latest: 20260724000005) sets current_fare/final_fare/
--     boost_amount/boost_percentage (via calculate_fare_breakdown) and is called directly by the
--     client (order_chat_screen.dart:638, supabase.rpc with the user's own JWT) -- but it already
--     calls `PERFORM set_config('app.bypass_financial_guard', 'true', true)` (line 264) before its
--     UPDATE, exactly the escape hatch this trigger already honors. Preserved below.
--   - boost-order-fare edge function: service_role, unaffected.
--   - Nothing else in supabase/migrations or supabase/functions sets any of these 4 columns.
-- This migration therefore requires zero changes to any RPC -- the existing bypass mechanism
-- already covers the one legitimate authenticated-role writer.

CREATE OR REPLACE FUNCTION public.protect_order_financial_columns()
RETURNS TRIGGER AS $$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.commission_amount IS DISTINCT FROM OLD.commission_amount
           OR NEW.gst_amount IS DISTINCT FROM OLD.gst_amount
           OR NEW.rider_earning IS DISTINCT FROM OLD.rider_earning
           OR NEW.commission_percentage IS DISTINCT FROM OLD.commission_percentage
           OR NEW.gst_percentage IS DISTINCT FROM OLD.gst_percentage
           OR NEW.actual_fare IS DISTINCT FROM OLD.actual_fare
           OR NEW.boost_rider_earning IS DISTINCT FROM OLD.boost_rider_earning
           OR NEW.boost_company_earning IS DISTINCT FROM OLD.boost_company_earning
           OR NEW.payment_status IS DISTINCT FROM OLD.payment_status
           OR NEW.fare_payment_method IS DISTINCT FROM OLD.fare_payment_method
           -- Added by this migration -- see header for why the prior carve-out no longer applies
           -- and why confirm_intercity_booking() (the one legitimate authenticated-role writer)
           -- is unaffected.
           OR NEW.current_fare IS DISTINCT FROM OLD.current_fare
           OR NEW.final_fare IS DISTINCT FROM OLD.final_fare
           OR NEW.boost_amount IS DISTINCT FROM OLD.boost_amount
           OR NEW.boost_percentage IS DISTINCT FROM OLD.boost_percentage
        THEN
            RAISE EXCEPTION 'Direct modification of order financial columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
