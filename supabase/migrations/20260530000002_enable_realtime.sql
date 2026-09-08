-- Safe replication helper to add tables if they aren't already part of the publication
DO $$
DECLARE
    t text;
    tables_list text[] := ARRAY['orders', 'riders', 'rider_assignments', 'rider_withdrawals', 'payments', 'users', 'rider_kyc'];
BEGIN
    -- Ensure publication exists
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        CREATE PUBLICATION supabase_realtime;
    END IF;

    FOREACH t IN ARRAY tables_list LOOP
        -- Check if table exists in public schema first to avoid referencing non-existent tables
        IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = t) THEN
            -- Check if it is already in the publication
            IF NOT EXISTS (
                SELECT 1 FROM pg_publication_tables 
                WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
            ) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
            
            -- Set replica identity to FULL for tracking filters on non-primary key columns
            EXECUTE format('ALTER TABLE public.%I REPLICA IDENTITY FULL', t);
        END IF;
    END LOOP;
END$$;
