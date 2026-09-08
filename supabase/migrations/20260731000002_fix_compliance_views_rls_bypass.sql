-- Migration: Close an RLS bypass on the parcel compliance/evidence views (found while auditing
-- the Delete-Account flow's "retained records must stay inaccessible to ordinary users"
-- requirement -- unrelated to account deletion itself, but a live privacy hole in the exact same
-- retained-evidence data the deletion flow depends on).
-- Date: 2026-07-31
--
-- public.parcel_compliance_view and public.parcel_security_timeline_view
-- (20260612000003_compliance_adjustments.sql) join sender_phone, IP address, GPS, device
-- fingerprint, and declared parcel value. 20260612000005_grant_compliance_permissions.sql grants
-- ALL on both views to `anon`. Views created by the migration-runner role evaluate row-security as
-- the VIEW OWNER, not the querying client, unless the view has security_invoker = true (default
-- false pre-PG15-option) -- so even though 20260715000003_fix_compliance_tables_rls.sql correctly
-- scoped SELECT on the underlying tables to order participants, these two views bypass that
-- entirely: any request carrying only the public anon key (shipped inside the compiled app) could
-- read every user's compliance/security data for every order, unauthenticated.
--
-- Fix: security_invoker = true makes both views re-check RLS as the querying role (so they now
-- correctly inherit the 20260715000003 participant-scoping), and anon is revoked outright --
-- there is no legitimate unauthenticated use of parcel compliance data. Also revoking anon from
-- the 6 underlying tables granted in 20260612000005: their RLS policies are `TO authenticated`
-- only so anon already got 0 rows in practice, but the table-level anon grant serves no purpose
-- and is unnecessary attack surface if RLS is ever misconfigured.

ALTER VIEW public.parcel_compliance_view SET (security_invoker = true);
ALTER VIEW public.parcel_security_timeline_view SET (security_invoker = true);

REVOKE ALL ON public.parcel_compliance_view FROM anon;
REVOKE ALL ON public.parcel_security_timeline_view FROM anon;

REVOKE ALL ON public.user_devices FROM anon;
REVOKE ALL ON public.parcel_security_logs FROM anon;
REVOKE ALL ON public.order_declarations FROM anon;
REVOKE ALL ON public.police_sos_logs FROM anon;
REVOKE ALL ON public.order_parcel_photos FROM anon;
REVOKE ALL ON public.parcel_compliance_reports FROM anon;
