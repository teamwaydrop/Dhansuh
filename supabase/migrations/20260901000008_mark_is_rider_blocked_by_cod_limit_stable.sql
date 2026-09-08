-- Migration: mark is_rider_blocked_by_cod_limit() STABLE (volatility declaration only).
--
-- ROOT CAUSE (find_nearby_riders forensic performance audit): is_rider_blocked_by_cod_limit()
-- (20260808000002_enforce_cod_limit_at_dispatch.sql) is a pure read-only function -- two SELECTs
-- against riders by primary key, no INSERT/UPDATE/DELETE, no sequence/random()/now() usage, no
-- side effects of any kind -- but was declared with no volatility category, which defaults to
-- VOLATILE. Its sibling, is_rider_blocked_by_tax_due() (20260726000004_government_tax_due_
-- functions.sql), performs the exact same shape of read (a COALESCE'd point lookup on riders by
-- id) and is already correctly marked STABLE. VOLATILE tells the planner this function's result
-- can change from call to call even for the same argument within the same statement and forbids
-- the optimizations STABLE allows -- neither is true here, so the current declaration is simply
-- wrong, not a deliberate choice.
--
-- SCOPE: this migration changes ONLY the volatility category. The function body is byte-for-byte
-- identical to the live definition -- same two SELECTs, same COALESCE fallbacks (0 / 500), same
-- parameter, same return type, same SECURITY DEFINER, same search_path. No caller is touched:
-- find_nearby_riders() calls this function exactly as before and is not modified by this
-- migration. No rider eligibility rule, no dispatch logic, no query structure, no RLS policy, and
-- no index is changed. No database data is modified.
CREATE OR REPLACE FUNCTION public.is_rider_blocked_by_cod_limit(p_rider_id uuid)
RETURNS boolean AS $$
    SELECT COALESCE(
        (SELECT cod_pending_amount FROM public.riders WHERE id = p_rider_id),
        0
    ) >= COALESCE(
        (SELECT cod_limit FROM public.riders WHERE id = p_rider_id),
        500
    );
$$ LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public;
