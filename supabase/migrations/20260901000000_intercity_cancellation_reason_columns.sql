-- Migration: schema support for Issues 1 & 2 -- individual accepted-passenger cancellation and
-- whole travel-plan cancellation both need a structured, queryable place to record WHY the
-- traveller cancelled, for audit purposes and for building professional passenger notifications.
--
-- INSPECTION (before adding anything, per instructions): rider_travel_plans has no reason/metadata
-- column at all. intercity_requests already has a precedent for this exact pattern --
-- `expiry_reason text` (a dedicated plain-text column, not just jsonb metadata) -- so
-- `cancelled_reason` on intercity_requests mirrors an existing, established convention on this
-- table rather than inventing a new one. Both new columns are nullable, additive, and touch no
-- existing row/behavior.

ALTER TABLE public.rider_travel_plans
    ADD COLUMN IF NOT EXISTS cancel_reason text;

ALTER TABLE public.intercity_requests
    ADD COLUMN IF NOT EXISTS cancelled_reason text;

COMMENT ON COLUMN public.rider_travel_plans.cancel_reason IS
    'Traveller-supplied reason when the entire travel plan is cancelled pre-trip via cancel_travel_plan_by_traveller(). Null for plans never cancelled.';

COMMENT ON COLUMN public.intercity_requests.cancelled_reason IS
    'Traveller-supplied reason when this specific request/booking is cancelled -- either individually (cancel_intercity_request_by_traveller()) or as part of a whole-plan cancellation cascade (cascade_cancel_travel_plan_dependents()). Mirrors the existing expiry_reason column''s convention on this same table.';
