-- Grant explicit SELECT, INSERT, UPDATE, and DELETE privileges on the user_device_tokens table to Supabase client roles
GRANT ALL ON TABLE public.user_device_tokens TO postgres, service_role, authenticated, anon;
