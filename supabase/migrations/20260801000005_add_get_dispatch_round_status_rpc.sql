-- Migration: Single-round-trip helper for start-dispatch's per-second wait loop.
-- Date: 2026-08-01
--
-- ROOT CAUSE (WayDrop Progressive Degradation Audit, finding EDGE-2): start-dispatch's per-round
-- wait loop (supabase/functions/start-dispatch/index.ts) runs two sequential, separately-awaited
-- queries every second for up to `timeoutSec` (default 30s) -- an `orders` status check, then a
-- `rider_assignments` pending-count check -- for every order currently being dispatched. Several
-- rides created within one session each keep their own worker alive for their full search window,
-- so N concurrently-searching orders add roughly 2N queries/second of shared DB load, on top of
-- everything else in the system. This is the audit's primary mechanical explanation for "cold start
-- fast, later requests in the same session slower."
--
-- Fix: a single read-only helper that returns both pieces of information the loop needs
-- (order_status, and the count of still-"sent" assignments for the round being waited on) in one
-- round trip instead of two. This does not change the loop's cadence (still one check per second),
-- its timeout values, or any dispatch/matching business rule -- it only halves the number of
-- queries issued per tick. Called exclusively by start-dispatch using the service-role key, which
-- already bypasses RLS on both underlying tables, so this executes with the same effective
-- permissions as the two queries it replaces.
CREATE OR REPLACE FUNCTION public.get_dispatch_round_status(
    p_order_id uuid,
    p_round integer
)
RETURNS TABLE(order_status text, pending_assignments integer)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT
        (SELECT o.order_status::text FROM public.orders o WHERE o.id = p_order_id) AS order_status,
        (
            SELECT COUNT(*)::integer
            FROM public.rider_assignments ra
            WHERE ra.order_id = p_order_id
              AND ra.assignment_round = p_round
              AND ra.assignment_status = 'sent'
        ) AS pending_assignments;
$$;

GRANT EXECUTE ON FUNCTION public.get_dispatch_round_status(uuid, integer) TO service_role;
