-- Migration: Fix traveller-initiated "Available Users" browsing returning nothing.
-- Date: 2026-07-21
--
-- ROOT CAUSE: AvailableTravelersScreen -> IntercityMatchingService.fetchAvailableTravelersForDate()
-- already runs the correct query (orders where order_status='searching', matching pickup/
-- destination city and date, joined to users for display fields) -- the whole traveller-initiated
-- UI/service/notification flow is already built and wired up. But public.orders only grants a
-- traveller SELECT access via check_is_order_candidate_rider() (the LOCAL dispatch/
-- rider_assignments table -- irrelevant to intercity) or, since 20260718000006, via an EXISTS
-- check against a *pre-existing* non-terminal intercity_requests row naming that traveller. A
-- traveller who hasn't sent a request yet has neither, so the query returns zero rows -- exactly
-- the reported "traveller only sees a user after that user has already sent a request" bug.
-- Same problem one level deeper on public.users (name/phone come back null).
--
-- This is the mirror-image of a gap that already doesn't exist on the other side: any authenticated
-- user may already view any `active` rider_travel_plans row with no negotiation-existence gate
-- (20260601000012_rider_travel_plans_policy.sql), and any authenticated user may already view any
-- `online` riders/rider_kyc row (20260531000003_fix_find_nearby_riders.sql). This migration makes
-- the traveller-browsing-passengers direction symmetric with that already-accepted trade-off,
-- scoped as narrowly as those precedents: only orders that are actively `searching` and only
-- intercity order types (mirrors the `order_type::text LIKE 'intercity%'` cast pattern used
-- elsewhere, since order_type is an enum with no LIKE operator).
--
-- Additive: Postgres OR-combines multiple permissive policies for the same command, so this layers
-- on top of the existing policies without touching or risking their current behavior.

CREATE POLICY "Allow travellers to browse searching intercity orders"
ON public.orders
FOR SELECT
TO authenticated
USING (
    order_status = 'searching'::public.order_status_enum
    AND order_type::text LIKE 'intercity%'
);

CREATE POLICY "Allow travellers to view profile of searching intercity passengers"
ON public.users
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.user_id = users.id
          AND o.order_status = 'searching'::public.order_status_enum
          AND o.order_type::text LIKE 'intercity%'
    )
);
