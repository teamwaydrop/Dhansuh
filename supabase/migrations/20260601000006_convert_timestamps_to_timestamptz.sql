-- Set database timezone to IST (Asia/Kolkata)
ALTER DATABASE postgres SET timezone TO 'Asia/Kolkata';

-- Also ensure Roles default to Asia/Kolkata
ALTER ROLE postgres SET timezone TO 'Asia/Kolkata';
ALTER ROLE authenticator SET timezone TO 'Asia/Kolkata';

-- Drop the trigger that depends on last_location_updated_at
DROP TRIGGER IF EXISTS trigger_assign_nearby_orders ON public.riders;

-- Convert all public schema columns of type 'timestamp without time zone' to 'timestamp with time zone' (timestamptz)
-- assuming that the current stored values represent UTC timings.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT table_schema, table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' 
          AND data_type = 'timestamp without time zone'
    LOOP
        RAISE NOTICE 'Converting column %.% to timestamptz', r.table_name, r.column_name;
        EXECUTE format(
            'ALTER TABLE %I.%I ALTER COLUMN %I TYPE timestamp with time zone USING %I AT TIME ZONE %L',
            r.table_schema, r.table_name, r.column_name, r.column_name, 'UTC'
        );
    END LOOP;
END $$;

-- Re-create the trigger trigger_assign_nearby_orders on riders table
CREATE TRIGGER trigger_assign_nearby_orders
AFTER UPDATE OF account_status, current_lat, current_lng, last_location_updated_at ON public.riders
FOR EACH ROW
WHEN (
    NEW.account_status = 'online' 
    AND (
        OLD.account_status IS DISTINCT FROM 'online' 
        OR NEW.current_lat IS DISTINCT FROM OLD.current_lat 
        OR NEW.current_lng IS DISTINCT FROM OLD.current_lng
        OR NEW.last_location_updated_at IS DISTINCT FROM OLD.last_location_updated_at
    )
)
EXECUTE FUNCTION public.assign_nearby_searching_orders_to_rider();
