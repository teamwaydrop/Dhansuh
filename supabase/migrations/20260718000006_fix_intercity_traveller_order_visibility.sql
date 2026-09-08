-- Migration: Fix "No Users Available" on TravelPlanDetailsScreen after a User sends a
-- Travel Together request to a Traveller's Travel Plan.
-- Date: 2026-07-18
--
-- ROOT CAUSE (traced live via the actual runtime flow, not guessed):
--   Travel Together -> IntercityMatchingService.sendTravelTogetherRequest() -> INSERT into
--   intercity_requests (route_id/traveller_id/sender_id all correct, status='request_sent')
--   -> on_intercity_request_change trigger fires -> push notification delivered correctly
--   -> Traveller taps it -> notification_service.dart opens the correct
--   TravelPlanDetailsScreen -> initState() -> IntercityMatchingService
--   .fetchIncomingRequestsForPlan() runs:
--
--       select('parcel_id, orders(*, users(full_name, phone, ...)))')
--         .eq('route_id', planId).eq('traveller_id', riderId)
--         .not('status', 'in', '(cancelled,rejected,expired)')
--
--   The intercity_requests row itself IS returned (its own SELECT policy already allows the
--   traveller: `EXISTS (SELECT 1 FROM riders r WHERE r.id = traveller_id AND r.user_id =
--   auth.uid())`). But PostgREST's embedded `orders(...)` resource is independently subject to
--   the `orders` table's own RLS. That policy ("Allow users to view their own or assigned
--   orders", 20260601000015_fix_orders_recursion.sql) only grants a rider read access via
--   check_is_order_candidate_rider(), which checks ONLY public.rider_assignments — the
--   local-ride dispatch table. Nothing in the intercity Travel Together flow ever inserts a
--   rider_assignments row, so that check is always false here, the embedded `orders` field
--   comes back null, and the Flutter loop (`if (orderData is Map) matches.add(...)`) silently
--   drops the row. Same problem one level deeper: the nested `users(full_name, phone, ...)`
--   embed is blocked too, since public.users only ever had one SELECT policy in this codebase
--   ("Users can view own profile", auth.uid() = id) — grepped every migration, confirmed no
--   other SELECT policy on public.users exists anywhere.
--
--   Net effect: the intercity_requests negotiation row exists, the notification fires, and the
--   correct Travel Plan opens exactly as the bug report describes — but the passenger's order
--   (and their name/phone) is invisible to the traveller until after acceptance, so the
--   Available Users list renders empty ("No Users Available").
--
-- FIX: two new, additive, narrowly-scoped SELECT policies (Postgres OR-combines multiple
-- permissive policies for the same command, so these layer on top of the existing policies
-- without touching or risking their current behavior):
--   1. orders: a traveller may view an order if they have a live (non-terminal) intercity_requests
--      row naming them as traveller for that order.
--   2. users: a traveller may view a passenger's basic profile under the same condition.
-- Both use the identical participant predicate already trusted elsewhere in this codebase
-- (intercity_requests policies, accept_intercity_offer, confirm_intercity_booking), scoped to
-- non-terminal statuses so visibility naturally follows the negotiation's lifecycle.

CREATE POLICY "Allow travellers to view orders tied to active intercity requests"
ON public.orders
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.intercity_requests ir
        INNER JOIN public.riders r ON r.id = ir.traveller_id
        WHERE ir.parcel_id = orders.id
          AND r.user_id = auth.uid()
          AND ir.status NOT IN ('cancelled', 'rejected', 'expired')
    )
);

CREATE POLICY "Allow travellers to view sender profile for active intercity requests"
ON public.users
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.intercity_requests ir
        INNER JOIN public.riders r ON r.id = ir.traveller_id
        WHERE ir.sender_id = users.id
          AND r.user_id = auth.uid()
          AND ir.status NOT IN ('cancelled', 'rejected', 'expired')
    )
);
