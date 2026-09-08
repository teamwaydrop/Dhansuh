-- Migration: Compliance Adjustments
-- Date: 2026-06-12

-- 1. Create public.user_devices Table
CREATE TABLE IF NOT EXISTS public.user_devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    device_id text UNIQUE NOT NULL,
    device_ref text UNIQUE NOT NULL,
    device_model text,
    device_brand text,
    os_version text,
    app_version text,
    last_ip_address inet,
    last_seen_at timestamptz DEFAULT now(),
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    is_active boolean DEFAULT true
);

-- Enable RLS on user_devices
ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;

-- Permissive RLS policies for user_devices
DROP POLICY IF EXISTS "Allow users to select their own devices" ON public.user_devices;
CREATE POLICY "Allow users to select their own devices"
ON public.user_devices
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Allow users to insert their own devices" ON public.user_devices;
CREATE POLICY "Allow users to insert their own devices"
ON public.user_devices
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Allow users to update their own devices" ON public.user_devices;
CREATE POLICY "Allow users to update their own devices"
ON public.user_devices
FOR UPDATE
TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- 2. Alter public.user_device_tokens to link to user_devices
ALTER TABLE public.user_device_tokens
ADD COLUMN IF NOT EXISTS user_device_id uuid REFERENCES public.user_devices(id) ON DELETE SET NULL;

-- 3. Alter public.orders for compliance metadata, retention, and device snapshots
ALTER TABLE public.orders
DROP COLUMN IF EXISTS created_device_id,
DROP COLUMN IF EXISTS pickup_verification_photo_url,
DROP COLUMN IF EXISTS pickup_verification_photo_taken_at,
DROP COLUMN IF EXISTS pickup_verification_lat,
DROP COLUMN IF EXISTS pickup_verification_lng;

ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS pickup_verification_completed boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS pickup_verification_completed_at timestamptz,
ADD COLUMN IF NOT EXISTS compliance_flagged boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS compliance_notes text,
ADD COLUMN IF NOT EXISTS created_device_ref text,
ADD COLUMN IF NOT EXISTS created_device_record_id uuid REFERENCES public.user_devices(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS created_device_model text,
ADD COLUMN IF NOT EXISTS created_device_brand text,
ADD COLUMN IF NOT EXISTS created_os_version text,
ADD COLUMN IF NOT EXISTS created_app_version text,
ADD COLUMN IF NOT EXISTS compliance_status text DEFAULT 'pending' CHECK (compliance_status IN ('pending', 'verified', 'flagged', 'investigating')),
ADD COLUMN IF NOT EXISTS compliance_score integer DEFAULT 100,
ADD COLUMN IF NOT EXISTS compliance_retention_until timestamptz,
ADD COLUMN IF NOT EXISTS parcel_declared_value numeric,
ADD COLUMN IF NOT EXISTS high_risk_parcel boolean DEFAULT false;

-- 4. Alter public.order_parcel_photos for photo classification & evidence integrity
ALTER TABLE public.order_parcel_photos
ADD COLUMN IF NOT EXISTS photo_type text NOT NULL DEFAULT 'pickup' CHECK (photo_type IN ('pickup', 'dropoff', 'damage', 'evidence', 'rider_selfie')),
ADD COLUMN IF NOT EXISTS file_sha256 text;

ALTER TABLE public.order_parcel_photos
ALTER COLUMN latitude TYPE numeric,
ALTER COLUMN longitude TYPE numeric;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'order_parcel_photos' AND column_name = 'taken_at'
    ) THEN
        ALTER TABLE public.order_parcel_photos RENAME COLUMN taken_at TO captured_at;
    ELSE
        ALTER TABLE public.order_parcel_photos ADD COLUMN IF NOT EXISTS captured_at timestamptz DEFAULT now();
    END IF;
END
$$;

-- 5. Alter public.order_declarations for declaration auditing
ALTER TABLE public.order_declarations
ADD COLUMN IF NOT EXISTS declaration_version text DEFAULT '1.0',
ADD COLUMN IF NOT EXISTS accepted_device_ref text;

-- 6. Alter public.police_sos_logs for reference codes & coordinates
ALTER TABLE public.police_sos_logs
ADD COLUMN IF NOT EXISTS police_reference_code text UNIQUE,
ADD COLUMN IF NOT EXISTS support_ticket_code text UNIQUE,
ADD COLUMN IF NOT EXISTS rider_lat numeric,
ADD COLUMN IF NOT EXISTS rider_lng numeric;

-- 7. Alter public.parcel_security_logs for rider event coordinates
ALTER TABLE public.parcel_security_logs
ADD COLUMN IF NOT EXISTS event_latitude numeric,
ADD COLUMN IF NOT EXISTS event_longitude numeric;

-- 8. Alter public.parcel_compliance_reports to match reporting layout
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' AND table_name = 'parcel_compliance_reports' AND column_name = 'report_data'
    ) THEN
        ALTER TABLE public.parcel_compliance_reports RENAME COLUMN report_data TO report_json;
    ELSE
        ALTER TABLE public.parcel_compliance_reports ADD COLUMN IF NOT EXISTS report_json jsonb DEFAULT '{}'::jsonb;
    END IF;
END
$$;

ALTER TABLE public.parcel_compliance_reports
ADD COLUMN IF NOT EXISTS generated_by uuid REFERENCES public.users(id) ON DELETE SET NULL;

-- 9. Guarantee Log Immutability (NO UPDATE, NO DELETE RLS Rules)
-- Drop existing update/delete policies for security and SOS logs to lock them
DROP POLICY IF EXISTS "Allow users/riders to update security logs" ON public.parcel_security_logs;
DROP POLICY IF EXISTS "Allow users/riders to delete security logs" ON public.parcel_security_logs;
DROP POLICY IF EXISTS "Allow riders to update police sos logs" ON public.police_sos_logs;
DROP POLICY IF EXISTS "Allow riders to delete police sos logs" ON public.police_sos_logs;

-- Ensure only SELECT and INSERT are active for security logs
ALTER TABLE public.parcel_security_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.police_sos_logs ENABLE ROW LEVEL SECURITY;

-- 10. Automated Reference Codes Trigger for police_sos_logs
CREATE OR REPLACE FUNCTION public.generate_police_reference_code()
RETURNS TRIGGER AS $$
DECLARE
    v_date text;
    v_random_sos text;
    v_random_sup text;
    v_code_sos text;
    v_code_sup text;
    v_exists boolean;
BEGIN
    v_date := to_char(NOW(), 'YYYYMMDD');
    
    -- Generate Police Reference Code (SOS-WDP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sos := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sos := 'SOS-WDP-' || v_date || '-' || v_random_sos;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE police_reference_code = v_code_sos) INTO v_exists;
        IF NOT v_exists THEN
            NEW.police_reference_code := v_code_sos;
            EXIT;
        END IF;
    END LOOP;
    
    -- Generate Support Ticket Code (SUP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sup := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sup := 'SUP-' || v_date || '-' || v_random_sup;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE support_ticket_code = v_code_sup) INTO v_exists;
        IF NOT v_exists THEN
            NEW.support_ticket_code := v_code_sup;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_police_sos_reference_code
BEFORE INSERT ON public.police_sos_logs
FOR EACH ROW
EXECUTE FUNCTION public.generate_police_reference_code();

-- 11. Automated Data Retention Trigger for orders (sets completed_at + 5 years)
CREATE OR REPLACE FUNCTION public.set_compliance_retention()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.order_status IN ('completed', 'delivered') AND OLD.order_status NOT IN ('completed', 'delivered')) THEN
        NEW.compliance_retention_until := NOW() + INTERVAL '5 years';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_orders_compliance_retention
BEFORE UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.set_compliance_retention();

-- 12. Create public.parcel_compliance_view
CREATE OR REPLACE VIEW public.parcel_compliance_view AS
SELECT
    o.id AS order_id,
    o.order_code,
    o.order_type,
    o.order_status,
    o.compliance_status,
    o.compliance_score,
    o.compliance_flagged,
    o.compliance_notes,
    o.parcel_declared_value,
    o.high_risk_parcel,
    o.created_device_ref,
    o.created_device_record_id,
    o.created_device_model,
    o.created_device_brand,
    o.created_os_version,
    o.created_app_version,
    o.created_ip_address,
    o.created_lat,
    o.created_lng,
    o.pickup_verification_completed,
    o.pickup_verification_completed_at,
    o.compliance_retention_until,
    
    -- Sender Details
    u.id AS sender_id,
    u.phone AS sender_phone,
    
    -- Declaration Details
    od.id AS declaration_id,
    od.declaration_version,
    od.declaration_text,
    od.accepted_at AS declaration_accepted_at,
    od.accepted_ip AS declaration_accepted_ip,
    od.accepted_device_ref AS declaration_accepted_device_ref,
    
    -- SOS Statistics
    (SELECT COUNT(*) FROM public.police_sos_logs psl WHERE psl.order_id = o.id) AS sos_trigger_count,
    
    -- Uploaded Photos Count
    (SELECT COUNT(*) FROM public.order_parcel_photos opp WHERE opp.order_id = o.id) AS photo_count
FROM public.orders o
LEFT JOIN public.users u ON u.id = o.user_id
LEFT JOIN public.order_declarations od ON od.order_id = o.id;

-- 13. Create public.parcel_security_timeline_view
CREATE OR REPLACE VIEW public.parcel_security_timeline_view AS
SELECT
    o.id AS order_id,
    o.order_code,
    psl.id AS log_id,
    psl.event_type,
    psl.event_latitude,
    psl.event_longitude,
    psl.created_at AS event_timestamp,
    psl.device_id,
    psl.metadata
FROM public.orders o
INNER JOIN public.parcel_security_logs psl ON psl.order_id = o.id
ORDER BY psl.created_at ASC;
