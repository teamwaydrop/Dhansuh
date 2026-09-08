-- Migration: reliability backstop for the rider-freed rematch (Issue 1).
--
-- ROOT CAUSE (confirmed via live-device production test + read-only production forensics, not
-- assumed): trigger_assign_nearby_orders_on_rider_freed (20260808000000, made async in
-- 20260809000001) enqueues a single, un-retried, fire-and-forget net.http_post call to
-- assign_nearby_searching_orders_core's PostgREST RPC endpoint, wrapped in a blanket
-- EXCEPTION WHEN OTHERS that RAISE WARNINGs (invisible outside server logs) on any failure.
--
-- A controlled real-device test reproduced the exact reported scenario: Rider A busy on Ride A,
-- Ride B created and correctly rejected (busy-guard working), Rider A completes Ride A (freed),
-- trigger condition confirmed satisfied, pg_net recorded a clean 204 response with no error/
-- timeout -- yet zero rows were ever written to rider_assignments or order_assignment_logs for
-- Rider A + Ride B, even though every one of assign_nearby_searching_orders_core's own eligibility
-- rules (radius, service_mode, vehicle, staleness, tax-block, COD-block) was independently
-- reproduced and confirmed passing for this exact pair using the historical values. This isolates
-- the failure to the async HTTP delivery/enqueue layer itself, which has no success confirmation
-- and no retry -- not to the matching function's business logic, which is unchanged and correct.
--
-- FIX: add the same backstop pattern already proven reliable for the order side
-- (redispatch_stalled_searching_orders, 20260808000003) -- a pg_cron job that runs every 20
-- seconds and calls the SAME, UNMODIFIED assign_nearby_searching_orders_core() directly and
-- synchronously (no HTTP/pg_net hop, so immune to the async layer's silent-failure mode) for any
-- online rider who currently has no order in the blocking set. The original async trigger is left
-- completely untouched -- this is a reliability net, not a replacement, exactly mirroring how the
-- order side already has both a synchronous fast path (trigger_assign_new_order_to_nearby_riders)
-- and a cron backstop for the same class of "an async/fire-and-forget step silently didn't
-- happen" problem.
--
-- UPDATE (still pre-deployment, folded into this same file rather than layered as a second
-- migration): the blocking set below now also excludes 'payment_pending', matching the coordinated
-- fix in 20260825000000_payment_pending_busy_state_fix.sql -- a rider whose current order is
-- awaiting payment confirmation is still busy and must not be offered Ride B by this backstop
-- either. This file was never deployed (supabase migration list --linked still shows no remote
-- entry for it at the time of this edit), so editing it in place rather than adding a second
-- migration on top keeps the history clean.
--
-- SCOPE / SAFETY:
--   - Busy-rider protection is preserved byte-for-byte relative to the corrected definition:
--     candidates are restricted to riders with NO order in ('accepted','rider_arrived',
--     'picked_up','ongoing','payment_pending') -- the exact same blocking set now used by
--     trigger_assign_nearby_orders_on_rider_freed's own WHEN clause and by
--     prevent_local_ride_assignment_to_busy_rider (which still runs, unmodified, on every write
--     this function's INSERT attempts -- this migration adds no new caller path around it).
--   - Bounded scan, not a full-fleet rescan: only riders who had an order updated in the last 5
--     minutes are considered, so this does not reintroduce the O(all online riders) rescan-per-
--     heartbeat problem that 20260806000002 deliberately eliminated -- the candidate set is
--     "riders who recently finished something," which is naturally small, not "everyone online."
--   - No matching rule is duplicated or changed: this calls assign_nearby_searching_orders_core()
--     as-is, so radius/service-mode/vehicle/weight matching, tax-due and COD-limit gating,
--     assignment uniqueness, and expires_at all come from that single, already-correct function.

CREATE OR REPLACE FUNCTION public.redispatch_freed_riders()
RETURNS void AS $$
DECLARE
    v_rider RECORD;
BEGIN
    FOR v_rider IN (
        SELECT r.id, r.user_id, r.current_lat, r.current_lng, r.service_mode
        FROM public.riders r
        WHERE r.account_status = 'online'
          AND r.current_lat IS NOT NULL
          AND r.current_lng IS NOT NULL
          AND EXISTS (
              -- had an order touched recently -- bounds the scan to "just finished something",
              -- not the full online fleet.
              SELECT 1 FROM public.orders o
              WHERE o.rider_id = r.id
                AND o.updated_at >= NOW() - INTERVAL '5 minutes'
          )
          AND NOT EXISTS (
              -- busy-rider protection: identical blocking set used everywhere else in this
              -- pipeline. A rider with any order still in one of these statuses is skipped.
              -- payment_pending included per the coordinated fix in
              -- 20260825000000_payment_pending_busy_state_fix.sql.
              SELECT 1 FROM public.orders bo
              WHERE bo.rider_id = r.id
                AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
          )
    ) LOOP
        PERFORM public.assign_nearby_searching_orders_core(
            v_rider.id,
            v_rider.user_id,
            v_rider.current_lat,
            v_rider.current_lng,
            v_rider.service_mode
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

SELECT cron.schedule(
    'redispatch-freed-riders',
    '20 seconds',
    $$SELECT public.redispatch_freed_riders();$$
);
