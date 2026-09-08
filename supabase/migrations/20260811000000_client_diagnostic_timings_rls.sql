-- TEMPORARY DIAGNOSTIC MIGRATION -- WayDrop Progressive Degradation Investigation (2026-08-11).
--
-- Extends public.diagnostic_timings (20260809000003) to also accept CLIENT-SIDE (Flutter app)
-- timing rows, so client-observed request duration can be correlated against the existing
-- server-side Edge Function timing already recorded there -- see
-- lib/core/services/diagnostics/client_request_diagnostics.dart.
--
-- Scope of the new privilege is intentionally narrow: `authenticated` may only INSERT rows, and
-- only with fn_name = 'flutter_client' (enforced by the policy's WITH CHECK, not just client-side
-- convention) -- this cannot be used to write rows under any other fn_name, and grants no SELECT/
-- UPDATE/DELETE at all (read access remains service_role/postgres only, unchanged).
--
-- DELETE THIS MIGRATION'S POLICY/GRANT (and the diagnostic_timings table itself, per
-- 20260809000003's own header) once the investigation concludes.

CREATE POLICY diagnostic_timings_client_insert ON public.diagnostic_timings
  FOR INSERT
  TO authenticated
  WITH CHECK (fn_name = 'flutter_client');

GRANT INSERT ON public.diagnostic_timings TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.diagnostic_timings_id_seq TO authenticated;
