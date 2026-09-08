-- Migration: Add compliance tables and columns for parcel safety and Police SOS auditing
-- Date: 2026-06-12

-- 1. Alter public.orders
ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS created_device_id text,
ADD COLUMN IF NOT EXISTS created_ip_address inet,
ADD COLUMN IF NOT EXISTS created_lat double precision,
ADD COLUMN IF NOT EXISTS created_lng double precision,
ADD COLUMN IF NOT EXISTS sender_declaration_accepted boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS sender_declaration_accepted_at timestamptz,
ADD COLUMN IF NOT EXISTS pickup_verification_photo_url text,
ADD COLUMN IF NOT EXISTS pickup_verification_photo_taken_at timestamptz,
ADD COLUMN IF NOT EXISTS pickup_verification_lat double precision,
ADD COLUMN IF NOT EXISTS pickup_verification_lng double precision;

-- 2. Alter public.user_device_tokens
ALTER TABLE public.user_device_tokens
ADD COLUMN IF NOT EXISTS device_id text,
ADD COLUMN IF NOT EXISTS device_model text,
ADD COLUMN IF NOT EXISTS device_brand text,
ADD COLUMN IF NOT EXISTS os_version text,
ADD COLUMN IF NOT EXISTS app_version text,
ADD COLUMN IF NOT EXISTS last_ip_address inet,
ADD COLUMN IF NOT EXISTS last_lat double precision,
ADD COLUMN IF NOT EXISTS last_lng double precision;

-- 3. Create public.parcel_security_logs
CREATE TABLE IF NOT EXISTS public.parcel_security_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id),
    sender_user_id uuid NOT NULL REFERENCES public.users(id),
    rider_id uuid REFERENCES public.riders(id),
    event_type text NOT NULL,
    photo_url text,
    latitude double precision,
    longitude double precision,
    ip_address inet,
    device_id text,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz DEFAULT now()
);

-- 4. Create public.order_declarations
CREATE TABLE IF NOT EXISTS public.order_declarations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id),
    user_id uuid NOT NULL REFERENCES public.users(id),
    declaration_text text NOT NULL,
    accepted boolean NOT NULL,
    accepted_ip inet,
    accepted_device_id text,
    accepted_at timestamptz DEFAULT now()
);

-- 5. Create public.police_sos_logs
CREATE TABLE IF NOT EXISTS public.police_sos_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id),
    rider_id uuid NOT NULL REFERENCES public.riders(id),
    opened_at timestamptz DEFAULT now(),
    latitude double precision,
    longitude double precision,
    notes text
);

-- 6. Create public.order_parcel_photos
CREATE TABLE IF NOT EXISTS public.order_parcel_photos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id),
    rider_id uuid NOT NULL REFERENCES public.riders(id),
    photo_url text NOT NULL,
    latitude double precision,
    longitude double precision,
    taken_at timestamptz DEFAULT now()
);

-- 7. Create public.parcel_compliance_reports
CREATE TABLE IF NOT EXISTS public.parcel_compliance_reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders(id),
    generated_for text,
    generated_at timestamptz DEFAULT now(),
    report_data jsonb NOT NULL
);

-- 8. Enable RLS on all new tables
ALTER TABLE public.parcel_security_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_declarations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.police_sos_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_parcel_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.parcel_compliance_reports ENABLE ROW LEVEL SECURITY;

-- 9. Add permissive RLS policies for operations
-- a) parcel_security_logs
DROP POLICY IF EXISTS "Allow authenticated users to insert security logs" ON public.parcel_security_logs;
CREATE POLICY "Allow authenticated users to insert security logs"
ON public.parcel_security_logs
FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow users/riders to select their parcel security logs" ON public.parcel_security_logs;
CREATE POLICY "Allow users/riders to select their parcel security logs"
ON public.parcel_security_logs
FOR SELECT
TO authenticated
USING (true);

-- b) order_declarations
DROP POLICY IF EXISTS "Allow users to insert order declarations" ON public.order_declarations;
CREATE POLICY "Allow users to insert order declarations"
ON public.order_declarations
FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow users to select their declarations" ON public.order_declarations;
CREATE POLICY "Allow users to select their declarations"
ON public.order_declarations
FOR SELECT
TO authenticated
USING (true);

-- c) police_sos_logs
DROP POLICY IF EXISTS "Allow riders to insert police sos logs" ON public.police_sos_logs;
CREATE POLICY "Allow riders to insert police sos logs"
ON public.police_sos_logs
FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated to select police sos logs" ON public.police_sos_logs;
CREATE POLICY "Allow authenticated to select police sos logs"
ON public.police_sos_logs
FOR SELECT
TO authenticated
USING (true);

-- d) order_parcel_photos
DROP POLICY IF EXISTS "Allow riders to insert parcel verification photos" ON public.order_parcel_photos;
CREATE POLICY "Allow riders to insert parcel verification photos"
ON public.order_parcel_photos
FOR INSERT
TO authenticated
WITH CHECK (true);

DROP POLICY IF EXISTS "Allow authenticated to select parcel verification photos" ON public.order_parcel_photos;
CREATE POLICY "Allow authenticated to select parcel verification photos"
ON public.order_parcel_photos
FOR SELECT
TO authenticated
USING (true);

-- e) parcel_compliance_reports
DROP POLICY IF EXISTS "Allow authenticated users to select compliance reports" ON public.parcel_compliance_reports;
CREATE POLICY "Allow authenticated users to select compliance reports"
ON public.parcel_compliance_reports
FOR SELECT
TO authenticated
USING (true);
