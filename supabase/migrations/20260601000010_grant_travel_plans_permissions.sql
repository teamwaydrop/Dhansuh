-- Grant explicit SELECT, INSERT, UPDATE, and DELETE privileges on the rider_travel_plans table to Supabase client roles
GRANT ALL ON TABLE public.rider_travel_plans TO postgres, service_role, authenticated, anon;
