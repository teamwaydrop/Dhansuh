-- =====================================================================
-- Migration: Scope compliance/SOS evidence table RLS to order participants (C9)
-- Date: 2026-07-15
-- Description: parcel_security_logs, order_declarations, police_sos_logs,
--              order_parcel_photos, and parcel_compliance_reports had RLS
--              enabled but with USING (true) / WITH CHECK (true) policies
--              for SELECT/INSERT — any authenticated user could read every
--              other user's SOS notes, GPS/IP/device data, and compliance
--              photos, and could insert forged records against any
--              order_id. Fix: scope SELECT/INSERT to order participants
--              (the order's own user_id, or its assigned rider), matching
--              the pattern already used correctly for order_verifications
--              (20260622000002).
--
--              Verified against actual call sites before writing this:
--              rider_active_order_screen.dart inserts directly into
--              police_sos_logs and parcel_security_logs from the rider's
--              own session for the SOS flow, using the order's own
--              order_id/rider_id — the new rider-scoped INSERT policies
--              below match that usage exactly. All other inserts to these
--              5 tables happen server-side via edge functions using the
--              service-role key, which bypasses RLS entirely and is
--              therefore unaffected by this migration.
--
--              UPDATE/DELETE remain blocked (no policies grant them,
--              consistent with the "log immutability" intent already
--              established in 20260612000003).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. parcel_security_logs — order participants (owner or assigned rider)
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow authenticated users to insert security logs" ON public.parcel_security_logs;
CREATE POLICY "Allow authenticated users to insert security logs"
ON public.parcel_security_logs
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = parcel_security_logs.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);

DROP POLICY IF EXISTS "Allow users/riders to select their parcel security logs" ON public.parcel_security_logs;
CREATE POLICY "Allow users/riders to select their parcel security logs"
ON public.parcel_security_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = parcel_security_logs.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);

-- ---------------------------------------------------------------------
-- 2. order_declarations — insert restricted to the declaring sender;
--    select open to order participants (rider may need to view it too)
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow users to insert order declarations" ON public.order_declarations;
CREATE POLICY "Allow users to insert order declarations"
ON public.order_declarations
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_declarations.order_id
      AND o.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Allow users to select their declarations" ON public.order_declarations;
CREATE POLICY "Allow users to select their declarations"
ON public.order_declarations
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_declarations.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);

-- ---------------------------------------------------------------------
-- 3. police_sos_logs — insert restricted to the assigned rider (matches
--    the confirmed real call site); select open to order participants
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow riders to insert police sos logs" ON public.police_sos_logs;
CREATE POLICY "Allow riders to insert police sos logs"
ON public.police_sos_logs
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = police_sos_logs.order_id
      AND o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "Allow authenticated to select police sos logs" ON public.police_sos_logs;
CREATE POLICY "Allow authenticated to select police sos logs"
ON public.police_sos_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = police_sos_logs.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);

-- ---------------------------------------------------------------------
-- 4. order_parcel_photos — insert restricted to the assigned rider;
--    select open to order participants
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow riders to insert parcel verification photos" ON public.order_parcel_photos;
CREATE POLICY "Allow riders to insert parcel verification photos"
ON public.order_parcel_photos
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_parcel_photos.order_id
      AND o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
  )
);

DROP POLICY IF EXISTS "Allow authenticated to select parcel verification photos" ON public.order_parcel_photos;
CREATE POLICY "Allow authenticated to select parcel verification photos"
ON public.order_parcel_photos
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_parcel_photos.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);

-- ---------------------------------------------------------------------
-- 5. parcel_compliance_reports — select open to order participants.
--    No INSERT policy existed before and none is added here (reports are
--    only ever generated server-side via the service role).
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "Allow authenticated users to select compliance reports" ON public.parcel_compliance_reports;
CREATE POLICY "Allow authenticated users to select compliance reports"
ON public.parcel_compliance_reports
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = parcel_compliance_reports.order_id
      AND (
        o.user_id = auth.uid()
        OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
      )
  )
);
