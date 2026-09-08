-- =====================================================================
-- Migration: Fix trip_share_tokens public SELECT policy (C7)
-- Date: 2026-07-15
-- Description: The original SELECT policy on public.trip_share_tokens
--              ("Allow public read of active unexpired share tokens")
--              has no TO clause and no predicate matching a specific
--              token, so it returns EVERY currently-valid row to any
--              caller — letting anyone enumerate every live "share my
--              trip" link on the platform.
--
--              Fix: remove the blanket table-level SELECT policy and
--              replace it with a SECURITY DEFINER RPC that only ever
--              returns the single row matching a token the caller
--              already supplies. Knowing the exact token (the secret
--              embedded in a share link) is what should grant access —
--              not being able to query the table directly.
--
--              No Flutter code currently reads this table directly, so
--              this is a database-only fix; the intended future
--              "view a shared trip" screen should call
--              rpc('get_trip_share_token', { p_token: ... }) instead of
--              selecting from the table.
-- =====================================================================

-- 1. Remove the public blanket-read policy.
DROP POLICY IF EXISTS "Allow public read of active unexpired share tokens" ON public.trip_share_tokens;

-- The existing owner/rider management policy (INSERT/UPDATE/DELETE/SELECT
-- for the order's own user_id/rider_id, added in 20260616000007) is
-- already correctly scoped and is left untouched.

-- 2. Secure single-token lookup RPC.
CREATE OR REPLACE FUNCTION public.get_trip_share_token(p_token varchar)
RETURNS TABLE (
  token_id uuid,
  order_id uuid,
  expires_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT t.token_id, t.order_id, t.expires_at
  FROM public.trip_share_tokens t
  WHERE t.token = p_token
    AND t.is_revoked = false
    AND t.expires_at > now();
END;
$$;

-- Callable by anyone holding the token (including logged-out recipients
-- of a share link, which is the point of the feature) or the app's own
-- authenticated users — but NOT a blanket table scan, since the function
-- only ever matches the exact token supplied as a parameter.
REVOKE EXECUTE ON FUNCTION public.get_trip_share_token(varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trip_share_token(varchar) TO anon, authenticated, service_role, postgres;
