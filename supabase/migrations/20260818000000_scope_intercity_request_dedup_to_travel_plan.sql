-- Migration: scope the intercity_requests duplicate-request guard to the specific travel plan
-- (route_id), not just (parcel_id, traveller_id).
--
-- ROOT CAUSE (Product/flow fix -- intercity travel plan request bug): a User who already sent a
-- request to Partner X for an OLDER travel plan (Travel Plan A) was incorrectly treated as already
-- having requested a NEWER travel plan the same Partner later publishes (Travel Plan B, same
-- route, new date). The Flutter UI's "already requested" lookups have been fixed separately
-- (intercity_matching_service.dart's sendTravelTogetherRequest/loadIntercityRequests in
-- intercity_searching_screen.dart now key on traveller_id + route_id, not traveller_id alone) --
-- this migration makes the DB-level guard agree, so the fix holds even under a race/retry, exactly
-- as idx_intercity_requests_one_active_per_order_traveller
-- (20260729000000_intercity_match_notification_wording_and_dedup.sql) already did for the
-- (parcel_id, traveller_id)-only case it superseded.
--
-- Genuine duplicate protection is preserved: a second request to the SAME travel plan (same
-- parcel_id + traveller_id + route_id) while an earlier one is still non-terminal is still
-- blocked, unchanged. Only a request for a DIFFERENT route_id (a different travel plan) is now
-- correctly treated as independent, per business requirement: "Request for Travel Plan A != Request
-- for Travel Plan B, even when same user/partner/route."
DROP INDEX IF EXISTS idx_intercity_requests_one_active_per_order_traveller;

CREATE UNIQUE INDEX IF NOT EXISTS idx_intercity_requests_one_active_per_order_traveller_plan
    ON public.intercity_requests (parcel_id, traveller_id, route_id)
    WHERE status NOT IN ('cancelled', 'rejected', 'expired', 'completed');
