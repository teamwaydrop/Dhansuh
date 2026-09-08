-- Migration: Grant compliance permissions to standard roles
-- Date: 2026-06-12

-- Grant privileges on tables
GRANT ALL ON TABLE public.user_devices TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.parcel_security_logs TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.order_declarations TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.police_sos_logs TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.order_parcel_photos TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.parcel_compliance_reports TO postgres, service_role, authenticated, anon;

-- Grant privileges on views
GRANT ALL ON TABLE public.parcel_compliance_view TO postgres, service_role, authenticated, anon;
GRANT ALL ON TABLE public.parcel_security_timeline_view TO postgres, service_role, authenticated, anon;
