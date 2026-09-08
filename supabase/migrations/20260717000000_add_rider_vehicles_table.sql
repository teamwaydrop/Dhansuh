-- Adds support for a Drop Partner (rider) owning multiple independently
-- verified vehicles (e.g. Bike + Car + Auto), without repeating the
-- one-time person KYC (Aadhaar/PAN/Driving License/Selfie/Bank Details in
-- rider_kyc, which remains unchanged and one-time).
--
-- The rider's original KYC vehicle (rider_kyc.vehicle_type/vehicle_number/
-- vehicle_image/RC images) continues to be treated by the app as their
-- first, already-approved vehicle (read directly from rider_kyc at query
-- time) — so no backfill of existing rows into this new table is required.
-- Existing approved Drop Partners keep working immediately with zero
-- migration of their historical data.

CREATE TABLE IF NOT EXISTS public.rider_vehicles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
  vehicle_type public.vehicle_type_enum NOT NULL,
  vehicle_number text NOT NULL,
  rc_front_image text NOT NULL,
  rc_back_image text NOT NULL,
  vehicle_image text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rider_vehicles_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_rider_vehicles_rider_id ON public.rider_vehicles(rider_id);
CREATE INDEX IF NOT EXISTS idx_rider_vehicles_status ON public.rider_vehicles(status);

ALTER TABLE public.rider_vehicles ENABLE ROW LEVEL SECURITY;

-- Mirrors the existing rider_travel_plans "own row via riders.user_id" RLS pattern.
CREATE POLICY "Riders can view own vehicles" ON public.rider_vehicles
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.riders r
      WHERE r.id = rider_vehicles.rider_id AND r.user_id = auth.uid()
    )
  );

CREATE POLICY "Riders can insert own vehicles" ON public.rider_vehicles
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.riders r
      WHERE r.id = rider_vehicles.rider_id AND r.user_id = auth.uid()
    )
  );

-- Every other client-facing table in this project needs an explicit table-level
-- GRANT in addition to its RLS policies (this project does not rely on default
-- privileges) — see e.g. 20260601000010_grant_travel_plans_permissions.sql for
-- rider_travel_plans. Without this, INSERT/SELECT from the app fails with
-- "permission denied for table rider_vehicles" even though the RLS policies
-- above are satisfied.
GRANT ALL ON TABLE public.rider_vehicles TO postgres, service_role, authenticated, anon;
